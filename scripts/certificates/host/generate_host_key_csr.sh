#!/usr/bin/env bash
#
# gen_csr.sh - Bulk RSA-4096 private key and CSR generator
#
# Reads host entries from host.list (or the file given as $1) in the format:
#   CN|FQDN|SAN_LIST|EXTENSIONS_LIST
#
# Outputs:
#   Keys : /srv/security/certificates/files/lab/<CN>/<CN>.key   (never overwritten)
#   CSRs : /srv/security/certificates/files/csr/<CN>.csr        (overwritten each run)
#
# Usage: ./gen_csr.sh [path/to/host.list]
#
# host.list rules:
#   - Lines beginning with '#' (optionally indented) are treated as commented
#     out and ignored, as are blank lines. Trailing ' # comment' text on an
#     entry is also ignored.
#
# CSR Distinguished Name attributes (C, ST, L, O, OU, emailAddress) are set by
# the CSR_* variables in the configuration section below. The CN is always the
# FQDN from the host entry. Any variable left empty is omitted from the CSR.
#
# Any setting can be overridden from the environment, e.g.:
#   CSR_ORG="My Company" CSR_COUNTRY=CA ./gen_csr.sh
#   CSR_EMAIL="" ./gen_csr.sh              # omit the emailAddress attribute
#   CSR_DIR / HOST_BASE_DIR                 # relocate the output folders
#   VERBOSE=1 ./gen_csr.sh                  # log each skipped/commented line

set -uo pipefail
umask 077   # keys/CSRs are created readable by the owner only

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
HOST_LIST="${1:-host.list}"
CSR_DIR="${CSR_DIR:-/srv/security/certificates/files/csr}"
HOST_BASE_DIR="${HOST_BASE_DIR:-/srv/security/certificates/files/$DOMAIN_NAME}"
KEY_BITS=4096
VERBOSE="${VERBOSE:-0}"

# ---- CSR Distinguished Name attributes (EDIT THESE) --------------------------
# Leave a value empty ("") to omit that attribute from the CSR.
CSR_COUNTRY="${CSR_COUNTRY-CA}"                    # C  - 2-letter ISO country code
CSR_STATE="${CSR_STATE-British Columbia}"          # ST - State or province
CSR_LOCALITY="${CSR_LOCALITY-Richmond}"            # L  - City / locality
CSR_ORG="${CSR_ORG-MDA Space}"                     # O  - Organization
CSR_OU="${CSR_OU-CHORUS Lab}"                      # OU - Organizational unit
CSR_EMAIL="${CSR_EMAIL-}"                          # emailAddress (optional)
# CN is taken from the FQDN field of each host.list entry.

# Recognised ExtendedKeyUsage names (dotted OIDs are also accepted)
VALID_EKUS="serverAuth clientAuth codeSigning emailProtection timeStamping OCSPSigning anyExtendedKeyUsage msSmartcardLogin msEFS msCodeInd msCodeCom msCTLSign msSGC nsSGC ipsecEndSystem ipsecTunnel ipsecUser"

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

_log() {  # _log COLOR LEVEL MESSAGE...
    local color="$1" level="$2"; shift 2
    printf '%s [%s%-7s%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$color" "$level" "$C_RESET" "$*"
}
log_info()    { _log "$C_BLUE"   "INFO"    "$@"; }
log_ok()      { _log "$C_GREEN"  "OK"      "$@"; }
log_warn()    { _log "$C_YELLOW" "WARN"    "$@" >&2; }
log_error()   { _log "$C_RED"    "ERROR"   "$@" >&2; }
log_created() { _log "$C_GREEN"  "CREATED" "$@"; }
log_exists()  { _log "$C_CYAN"   "EXISTS"  "$@"; }
log_over()    { _log "$C_YELLOW" "OVERWRT" "$@"; }

# ----------------------------------------------------------------------------
# Utility functions
# ----------------------------------------------------------------------------
trim() {
    local s="${1//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_valid_cn()   { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
is_valid_fqdn() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.*_-]*[A-Za-z0-9])?$ ]]; }
is_valid_dns()  { is_valid_fqdn "$1"; }
is_valid_ipv4() {
    local ip="$1" o
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $ip; do (( 10#$o <= 255 )) || return 1; done
    return 0
}
is_valid_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

is_valid_eku() {
    local eku="$1" v
    [[ "$eku" =~ ^[0-9]+(\.[0-9]+)+$ ]] && return 0   # dotted OID
    for v in $VALID_EKUS; do [[ "$eku" == "$v" ]] && return 0; done
    return 1
}

# Emit a quoted DN line for the OpenSSL config only when the value is non-empty.
emit_dn() {
    local key="$1" val="$2"
    [[ -n "$val" ]] && printf '%s = "%s"\n' "$key" "$val"
    return 0
}

# Validate the CSR_* DN variables once, before any host is processed.
validate_dn_settings() {
    local name val ok=0
    local bad_re='[$"\\]'
    CSR_COUNTRY="${CSR_COUNTRY^^}"

    if [[ -n "$CSR_COUNTRY" && ! "$CSR_COUNTRY" =~ ^[A-Z]{2}$ ]]; then
        log_error "CSR_COUNTRY must be a 2-letter country code (got '$CSR_COUNTRY')"
        ok=1
    fi
    for name in CSR_COUNTRY CSR_STATE CSR_LOCALITY CSR_ORG CSR_OU CSR_EMAIL; do
        val="${!name}"
        if [[ "$val" =~ $bad_re || "$val" == *$'\n'* ]]; then
            log_error "$name contains an unsupported character (\$ \" \\ or newline)"
            ok=1
        fi
    done
    if [[ -n "$CSR_EMAIL" && ! "$CSR_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
        log_error "CSR_EMAIL is not a valid email address (got '$CSR_EMAIL')"
        ok=1
    fi
    return $ok
}

TMP_CONF=""
cleanup() { [[ -n "$TMP_CONF" && -f "$TMP_CONF" ]] && rm -f "$TMP_CONF"; }
trap cleanup EXIT
trap 'log_error "Interrupted."; exit 130' INT TERM

# Create a directory and report whether it was created or already existed.
ensure_dir() {
    local dir="$1" label="$2"
    if [[ -d "$dir" ]]; then
        log_exists "$label folder already exists: $dir"
    else
        if mkdir -p "$dir" 2>/dev/null; then
            log_created "$label folder created: $dir"
        else
            log_error "Unable to create $label folder: $dir (check permissions / try sudo)"
            return 1
        fi
    fi
    if [[ ! -w "$dir" ]]; then
        log_error "$label folder is not writable: $dir"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Process one host entry
# ----------------------------------------------------------------------------
process_host() {
    local lineno="$1" cn="$2" fqdn="$3" san_list="$4" eku_list="$5"

    local host_dir="${HOST_BASE_DIR}/${cn}"
    local key_file="${host_dir}/${cn}.key"
    local csr_file="${CSR_DIR}/${cn}.csr"

    # ---- Validate fields ---------------------------------------------------
    if ! is_valid_cn "$cn"; then
        log_error "Line $lineno: invalid CN '$cn' (allowed: letters, digits, '.', '_', '-')"
        return 1
    fi
    if ! is_valid_fqdn "$fqdn"; then
        log_error "Line $lineno [$cn]: invalid FQDN '$fqdn'"
        return 1
    fi

    # ---- Parse SAN list ----------------------------------------------------
    local -a dns_names=() ip_addrs=()
    local entry value
    if [[ -n "$san_list" ]]; then
        local -a san_items
        IFS=',' read -r -a san_items <<< "$san_list"
        for entry in "${san_items[@]}"; do
            entry="$(trim "$entry")"
            [[ -z "$entry" ]] && continue
            case "$entry" in
                DNS:*)
                    value="${entry#DNS:}"
                    if is_valid_dns "$value"; then
                        dns_names+=("$value")
                    else
                        log_error "Line $lineno [$cn]: invalid DNS SAN '$entry'"
                        return 1
                    fi
                    ;;
                IP:*)
                    value="${entry#IP:}"
                    if is_valid_ipv4 "$value" || is_valid_ipv6 "$value"; then
                        ip_addrs+=("$value")
                    else
                        log_error "Line $lineno [$cn]: invalid IP SAN '$entry'"
                        return 1
                    fi
                    ;;
                *)
                    log_error "Line $lineno [$cn]: SAN '$entry' must start with DNS: or IP:"
                    return 1
                    ;;
            esac
        done
    fi

    # ---- Parse EKU list ----------------------------------------------------
    local -a ekus=()
    if [[ -n "$eku_list" ]]; then
        local -a eku_items
        IFS=',' read -r -a eku_items <<< "$eku_list"
        for entry in "${eku_items[@]}"; do
            entry="$(trim "$entry")"
            [[ -z "$entry" ]] && continue
            if is_valid_eku "$entry"; then
                ekus+=("$entry")
            else
                log_error "Line $lineno [$cn]: unsupported extension '$entry'"
                return 1
            fi
        done
    fi

    log_info "Processing host '$cn' ($fqdn)"

    # ---- Output folders ----------------------------------------------------
    ensure_dir "$host_dir" "Host" || return 1
    ensure_dir "$CSR_DIR"  "CSR"  || return 1

    # ---- Private key (never overwritten) -----------------------------------
    if [[ -e "$key_file" ]]; then
        log_warn "Private key already exists, NOT overwriting: $key_file"
        if ! openssl rsa -in "$key_file" -noout >/dev/null 2>&1; then
            log_error "Existing key file is not a valid, readable RSA key: $key_file"
            return 1
        fi
    else
        log_info "Generating RSA ${KEY_BITS}-bit private key: $key_file"
        if ! openssl genrsa -out "$key_file" "$KEY_BITS" >/dev/null 2>&1; then
            log_error "Failed to generate private key for '$cn'"
            rm -f "$key_file"
            return 1
        fi
        chmod 600 "$key_file"
        log_created "Private key created: $key_file"
    fi

    # ---- Build temporary OpenSSL config ------------------------------------
    TMP_CONF="$(mktemp "${TMPDIR:-/tmp}/csr_${cn}.XXXXXX")" || {
        log_error "Unable to create temporary config file"; return 1; }

    {
        echo "[ req ]"
        echo "default_md         = sha256"
        echo "prompt             = no"
        echo "string_mask        = utf8only"
        echo "distinguished_name = req_dn"
        echo "req_extensions     = req_ext"
        echo
        echo "[ req_dn ]"
        emit_dn "C"            "$CSR_COUNTRY"
        emit_dn "ST"           "$CSR_STATE"
        emit_dn "L"            "$CSR_LOCALITY"
        emit_dn "O"            "$CSR_ORG"
        emit_dn "OU"           "$CSR_OU"
        emit_dn "CN"           "$fqdn"
        emit_dn "emailAddress" "$CSR_EMAIL"
        echo
        echo "[ req_ext ]"
        echo "basicConstraints = CA:FALSE"
        echo "keyUsage         = critical, digitalSignature, keyEncipherment"
        if (( ${#ekus[@]} > 0 )); then
            local IFS=','
            echo "extendedKeyUsage = ${ekus[*]}"
        fi
        if (( ${#dns_names[@]} + ${#ip_addrs[@]} > 0 )); then
            echo "subjectAltName   = @alt_names"
            echo
            echo "[ alt_names ]"
            local i=1
            for value in "${dns_names[@]+"${dns_names[@]}"}"; do
                echo "DNS.${i} = ${value}"; ((i++))
            done
            i=1
            for value in "${ip_addrs[@]+"${ip_addrs[@]}"}"; do
                echo "IP.${i} = ${value}"; ((i++))
            done
        fi
    } > "$TMP_CONF"

    # ---- Generate CSR (overwritten each run) -------------------------------
    local overwrote=0
    [[ -e "$csr_file" ]] && overwrote=1

    local csr_tmp="${csr_file}.tmp.$$"
    if ! openssl req -new -key "$key_file" -config "$TMP_CONF" -out "$csr_tmp" 2>/dev/null; then
        log_error "Failed to generate CSR for '$cn'"
        rm -f "$csr_tmp" "$TMP_CONF"; TMP_CONF=""
        return 1
    fi

    if ! openssl req -in "$csr_tmp" -verify -noout >/dev/null 2>&1; then
        log_error "CSR signature verification failed for '$cn'"
        rm -f "$csr_tmp" "$TMP_CONF"; TMP_CONF=""
        return 1
    fi

    if ! mv -f "$csr_tmp" "$csr_file"; then
        log_error "Unable to write CSR to $csr_file"
        rm -f "$csr_tmp" "$TMP_CONF"; TMP_CONF=""
        return 1
    fi
    chmod 644 "$csr_file"
    rm -f "$TMP_CONF"; TMP_CONF=""

    if (( overwrote )); then
        log_over "Existing CSR was overwritten: $csr_file"
    else
        log_created "CSR created: $csr_file"
    fi
    log_ok "Completed '$cn'  [CN=${fqdn}; SANs: ${san_list:-none}; EKU: ${eku_list:-none}]"
    return 0
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    if ! command -v openssl >/dev/null 2>&1; then
        log_error "openssl is not installed or not in PATH."
        exit 2
    fi
    if [[ ! -f "$HOST_LIST" ]]; then
        log_error "Host list file not found: $HOST_LIST"
        exit 2
    fi
    if [[ ! -r "$HOST_LIST" ]]; then
        log_error "Host list file is not readable: $HOST_LIST"
        exit 2
    fi

    log_info "Using host list : $HOST_LIST"
    log_info "Key base folder : $HOST_BASE_DIR"
    log_info "CSR folder      : $CSR_DIR"
    log_info "OpenSSL         : $(openssl version)"

    if ! validate_dn_settings; then
        log_error "Fix the CSR_* distinguished name settings and re-run."
        exit 2
    fi
    log_info "DN attributes   : C=${CSR_COUNTRY:-<unset>}, ST=${CSR_STATE:-<unset>}, L=${CSR_LOCALITY:-<unset>}, O=${CSR_ORG:-<unset>}, OU=${CSR_OU:-<unset>}, emailAddress=${CSR_EMAIL:-<unset>}"
    echo

    local lineno=0 total=0 success=0 failed=0 skipped=0
    local raw line cn fqdn san_list eku_list extra

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        ((lineno++))
        line="$(trim "$raw")"

        # Ignore blank lines and commented-out lines (optionally indented)
        if [[ -z "$line" ]]; then
            continue
        elif [[ "$line" == \#* ]]; then
            ((skipped++))
            (( VERBOSE )) && log_info "Line $lineno: commented out, skipping"
            continue
        fi

        # Strip a trailing inline comment ('#' is not valid in any field)
        line="$(trim "${line%%[[:space:]]#*}")"

        ((total++))
        IFS='|' read -r cn fqdn san_list eku_list extra <<< "$line"
        cn="$(trim "${cn:-}")"
        fqdn="$(trim "${fqdn:-}")"
        san_list="$(trim "${san_list:-}")"
        eku_list="$(trim "${eku_list:-}")"

        if [[ -z "$cn" || -z "$fqdn" ]]; then
            log_error "Line $lineno: CN and FQDN are required -> '$line'"
            ((failed++)); echo; continue
        fi
        if [[ -n "${extra:-}" ]]; then
            log_error "Line $lineno [$cn]: too many fields (expected 4, separated by '|')"
            ((failed++)); echo; continue
        fi

        if process_host "$lineno" "$cn" "$fqdn" "$san_list" "$eku_list"; then
            ((success++))
        else
            ((failed++))
        fi
        echo
    done < "$HOST_LIST"

    log_info "------------------------------------------------------------"
    log_info "Summary: $total host(s) processed, $success succeeded, $failed failed, $skipped commented line(s) ignored"
    if (( total == 0 )); then
        log_warn "No host entries found in $HOST_LIST"
        exit 1
    fi
    (( failed == 0 )) || exit 1
    exit 0
}

main
