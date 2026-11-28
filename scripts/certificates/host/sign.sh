#!/usr/bin/env bash
#
# sign_csr.sh - Bulk CSR signing with an OpenSSL CA
#
# Reads "sign.list" (or the file given as $1), one entry per line:
#   CN|EXTENSION_PROFILE
#
# For each entry the script:
#   * reads the CSR   : /srv/security/certificates/files/csr/<CN>.csr
#   * signs it with   : /srv/security/certificates/files/lab/ca/private/ca.key.pem
#                       using the profile (extension section) from
#                       /srv/security/certificates/files/lab/ca/openssl.conf
#   * writes the cert : /srv/security/certificates/files/lab/<CN>/<CN>.crt
#   * writes the chain: /srv/security/certificates/files/lab/<CN>/<CN>.fullchain.crt
#                       (issued certificate + root CA certificate)
#   * exports PKCS#12 : /srv/security/certificates/files/lab/<CN>/<CN>.p12
#                       (private key <CN>.key + signed certificate + root CA)
#                       protected with the password "changeit".
#                       If <CN>.key does not exist the .p12 is skipped and the
#                       reason is logged. An existing .p12 is never overwritten.
#                       This also runs for entries whose certificate already
#                       exists, so a missing .p12 can be filled in on a re-run.
#
# Rules:
#   - The CA key must be RSA 4096-bit; certificates are signed with SHA-256.
#   - The subject DN is taken as-is from the CSR (-preserveDN).
#   - The Subject Alternative Names are taken from the CSR. All other
#     extensions (keyUsage, EKU, basicConstraints, ...) come from the profile.
#   - Existing certificates are NEVER overwritten: the error is logged and
#     the script moves on to the next entry.
#   - Lines beginning with '#' (optionally indented) and blank lines are
#     ignored, as is any trailing ' # comment' on an entry.
#
# Usage: ./sign_csr.sh [path/to/sign.list]
#
# Optional environment overrides:
#   CA_KEY_PASSIN="pass:secret"|"file:/path"|"env:VAR"   passphrase for the CA key
#                                (if the key is encrypted and this is unset,
#                                 you are prompted once at startup)
#   P12_PASSWORD="pass:changeit"  password argument for the .p12 (any openssl
#                                pass phrase argument: pass:, file:, env:)
#   P12_INCLUDE_CHAIN=0          do not include the root CA cert in the .p12
#   CERT_DAYS=365                override the validity period (default: the
#                                'default_days' value in openssl.conf)
#   VERBOSE=1                    log each commented-out line that is skipped
#   CSR_DIR, HOST_BASE_DIR, CA_DIR, CA_CONF, CA_KEY, CA_CERT, CA_INDEX,
#   CA_SERIAL                    relocate any of the paths below
#
# OpenSSL 3.x writes .p12 files with modern encryption (AES-256 and a SHA-256 MAC).
# Some older tools, such as Java before 8u301 or older Windows, can't read those.
# If you hit that, add -legacy to the pkcs12 command in the script.

set -uo pipefail
umask 077

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SIGN_LIST="${1:-sign.list}"

CSR_DIR="${CSR_DIR:-/srv/security/certificates/files/csr}"
HOST_BASE_DIR="${HOST_BASE_DIR:-/srv/security/certificates/files/$DOMAIN_NAME}"
CA_DIR="${CA_DIR:-/srv/security/certificates/files/$DOMAIN_NAME/ca}"
CA_CONF="${CA_CONF:-${CA_DIR}/openssl.cnf}"
CA_KEY="${CA_KEY:-${CA_DIR}/private/ca.key.pem}"
CA_CERT="${CA_CERT:-${CA_DIR}/ca.cert.pem}"
CA_INDEX="${CA_INDEX:-${CA_DIR}/index.txt}"
CA_SERIAL="${CA_SERIAL:-${CA_DIR}/serial}"

KEY_BITS=4096
DIGEST="sha256"
CERT_DAYS="${CERT_DAYS:-}"
VERBOSE="${VERBOSE:-0}"
P12_PASSWORD="${P12_PASSWORD:-pass:changeit}"
P12_INCLUDE_CHAIN="${P12_INCLUDE_CHAIN:-1}"

# PKCS#12 counters (updated by export_p12)
P12_CREATED=0; P12_EXISTS=0; P12_NOKEY=0; P12_FAILED=0

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

# ----------------------------------------------------------------------------
# Utility functions
# ----------------------------------------------------------------------------
WORK_DIR=""
cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
    unset SIGN_CA_PASS 2>/dev/null || true
}
trap cleanup EXIT
trap 'log_error "Interrupted."; exit 130' INT TERM

trim() {
    local s="${1//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_valid_cn()      { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
is_valid_profile() { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]; }

# Log multi-line command output, one log line per output line.
log_output() {  # log_output LEVEL_FUNC TEXT
    local fn="$1" text="$2" l
    while IFS= read -r l; do
        [[ -n "$l" ]] && "$fn" "    openssl: $l"
    done <<< "$text"
}

PASSIN_ARGS=()

# Work out how to unlock the CA key (once, up front).
# Uses $CA_PASSPHRASE if set; otherwise prompts if the key is encrypted.
setup_passin() {
    if [[ -z "${CA_PASSPHRASE:-}" ]] && grep -q "ENCRYPTED" "$CA_KEY" 2>/dev/null; then
        if [[ -t 0 && -t 2 ]]; then
            read -r -s -p "Enter passphrase for CA key ${CA_KEY}: " CA_PASSPHRASE
            echo >&2
        else
            log_error "CA key is encrypted and no terminal is available. Set the CA_PASSPHRASE environment variable."
            return 1
        fi
    fi

    if [[ -n "${CA_PASSPHRASE:-}" ]]; then
        # Passed by reference (env:), so it never appears in the process list.
        export CA_PASSPHRASE
        PASSIN_ARGS=(-passin env:CA_PASSPHRASE)
    fi
    return 0
}

# Extract "NNNN" from "(NNNN bit" in openssl text output on stdin.
parse_bits() { grep -oE '\([0-9]+ bit' | head -n1 | tr -dc '0-9'; }

# Return the SAN list of a CSR in openssl config syntax (DNS:a,IP:1.2.3.4).
get_csr_san() {
    openssl req -in "$1" -noout -text 2>/dev/null | awk '
        /X509v3 Subject Alternative Name/ { getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }'
}

# ----------------------------------------------------------------------------
# Startup checks of the CA
# ----------------------------------------------------------------------------
check_ca() {
    local f
    for f in "$CA_CONF" "$CA_KEY" "$CA_CERT"; do
        if [[ ! -r "$f" ]]; then
            log_error "Required CA file not found or not readable: $f"
            return 1
        fi
    done
    for f in "$CA_INDEX" "$CA_SERIAL"; do
        if [[ ! -f "$f" ]]; then
            log_warn "CA database file not found: $f (openssl ca will fail unless openssl.conf points elsewhere)"
        elif [[ ! -w "$f" ]]; then
            log_error "CA database file is not writable: $f"
            return 1
        fi
    done

    setup_passin || return 1

    # CA key must be RSA 4096
    local bits
    bits="$(openssl rsa -in "$CA_KEY" -noout -text "${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"}" 2>/dev/null | parse_bits)"
    if [[ -z "$bits" ]]; then
        log_error "Unable to read CA key as an RSA key (wrong passphrase or not an RSA key): $CA_KEY"
        return 1
    fi
    if [[ "$bits" != "$KEY_BITS" ]]; then
        log_error "CA key is ${bits}-bit; ${KEY_BITS}-bit RSA is required."
        return 1
    fi

    # CA certificate must be valid and match the key
    if ! openssl x509 -in "$CA_CERT" -noout >/dev/null 2>&1; then
        log_error "CA certificate is not a valid PEM certificate: $CA_CERT"
        return 1
    fi
    if ! openssl x509 -in "$CA_CERT" -noout -checkend 0 >/dev/null 2>&1; then
        log_error "CA certificate has expired: $CA_CERT"
        return 1
    fi
    local pub_key pub_cert
    pub_key="$(openssl pkey -in "$CA_KEY" -pubout "${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"}" 2>/dev/null)"
    pub_cert="$(openssl x509 -in "$CA_CERT" -noout -pubkey 2>/dev/null)"
    if [[ -z "$pub_key" || "$pub_key" != "$pub_cert" ]]; then
        log_error "CA key does not match the CA certificate ($CA_KEY vs $CA_CERT)"
        return 1
    fi

    log_ok "CA verified: ${KEY_BITS}-bit RSA key matches $(openssl x509 -in "$CA_CERT" -noout -subject | sed 's/^subject= *//')"
    return 0
}

# ----------------------------------------------------------------------------
# Export <CN>.p12 (private key + signed certificate [+ root CA]).
# Never fatal to the signing result; outcomes are counted in P12_* counters.
# ----------------------------------------------------------------------------
export_p12() {
    local cn="$1"
    local host_dir="${HOST_BASE_DIR}/${cn}"
    local key="${host_dir}/${cn}.key"
    local crt="${host_dir}/${cn}.crt"
    local p12="${host_dir}/${cn}.p12"
    local tmp_p12="${WORK_DIR}/${cn}.p12"
    local out

    if [[ ! -f "$key" ]]; then
        log_warn "[$cn] PKCS#12 skipped: private key not found: $key"
        ((P12_NOKEY++))
        return 0
    fi
    if [[ ! -s "$crt" ]]; then
        log_warn "[$cn] PKCS#12 skipped: signed certificate not found: $crt"
        ((P12_NOKEY++))
        return 0
    fi
    if [[ -e "$p12" ]]; then
        log_exists "[$cn] PKCS#12 already exists, NOT overwriting: $p12"
        ((P12_EXISTS++))
        return 0
    fi

    # The key must be readable (unencrypted) and must belong to the certificate
    local pub_key pub_crt
    pub_key="$(openssl pkey -in "$key" -pubout -passin pass: 2>/dev/null)"
    if [[ -z "$pub_key" ]]; then
        log_error "[$cn] PKCS#12 skipped: unable to read private key (encrypted or invalid): $key"
        ((P12_FAILED++))
        return 0
    fi
    pub_crt="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)"
    if [[ "$pub_key" != "$pub_crt" ]]; then
        log_error "[$cn] PKCS#12 skipped: private key does not match the certificate ($key vs $crt)"
        ((P12_FAILED++))
        return 0
    fi

    local -a chain_args=()
    (( P12_INCLUDE_CHAIN )) && chain_args=(-certfile "$CA_CERT")

    rm -f "$tmp_p12"
    if ! out="$(openssl pkcs12 -export \
            -inkey "$key" -in "$crt" \
            "${chain_args[@]+"${chain_args[@]}"}" \
            -name "$cn" \
            -passin pass: \
            -password "$P12_PASSWORD" \
            -out "$tmp_p12" 2>&1)" || [[ ! -s "$tmp_p12" ]]; then
        log_error "[$cn] PKCS#12 export failed"
        log_output log_error "$out"
        rm -f "$tmp_p12"
        ((P12_FAILED++))
        return 0
    fi

    # Confirm the bundle can be read back with the password
    if ! openssl pkcs12 -in "$tmp_p12" -noout -passin "$P12_PASSWORD" >/dev/null 2>&1; then
        log_error "[$cn] PKCS#12 file failed read-back verification"
        rm -f "$tmp_p12"
        ((P12_FAILED++))
        return 0
    fi

    if ! mv -n "$tmp_p12" "$p12" 2>/dev/null || [[ ! -s "$p12" ]]; then
        log_error "[$cn] Unable to write PKCS#12 file: $p12"
        rm -f "$tmp_p12"
        ((P12_FAILED++))
        return 0
    fi
    chmod 600 "$p12"
    log_created "PKCS#12 created: $p12"
    ((P12_CREATED++))
    return 0
}

# ----------------------------------------------------------------------------
# Sign one entry.
# Return codes: 0 = signed, 1 = failed, 3 = skipped (certificate already exists)
# ----------------------------------------------------------------------------
process_entry() {
    local lineno="$1" cn="$2" profile="$3"

    local csr="${CSR_DIR}/${cn}.csr"
    local host_dir="${HOST_BASE_DIR}/${cn}"
    local crt="${host_dir}/${cn}.crt"
    local chain="${host_dir}/${cn}.fullchain.crt"

    # ---- Validate input ----------------------------------------------------
    if ! is_valid_cn "$cn"; then
        log_error "Line $lineno: invalid CN '$cn' (allowed: letters, digits, '.', '_', '-')"
        return 1
    fi
    if ! is_valid_profile "$profile"; then
        log_error "Line $lineno [$cn]: invalid extension profile name '$profile'"
        return 1
    fi

    log_info "Processing '$cn' with profile '$profile'"

    # ---- Never overwrite an existing certificate ---------------------------
    if [[ -e "$crt" ]]; then
        log_error "Certificate already exists, NOT overwriting: $crt"
        export_p12 "$cn"
        return 3
    fi
    if [[ -e "$chain" ]]; then
        log_error "Full chain file already exists, NOT overwriting: $chain"
        return 3
    fi

    # ---- Check the profile exists in the CA config -------------------------
    if ! grep -Eq "^[[:space:]]*\[[[:space:]]*${profile}[[:space:]]*\]" "$CA_CONF"; then
        log_error "[$cn] Extension profile '[$profile]' not found in $CA_CONF"
        return 1
    fi

    # ---- Check the CSR -----------------------------------------------------
    if [[ ! -f "$csr" ]]; then
        log_error "[$cn] CSR not found: $csr"
        return 1
    fi
    if ! openssl req -in "$csr" -noout -verify >/dev/null 2>&1; then
        log_error "[$cn] CSR is invalid or its signature does not verify: $csr"
        return 1
    fi
    local csr_bits
    csr_bits="$(openssl req -in "$csr" -noout -text 2>/dev/null | grep -E 'Public-Key:' | parse_bits)"
    if [[ "$csr_bits" != "$KEY_BITS" ]]; then
        log_error "[$cn] CSR public key is ${csr_bits:-unknown}-bit; ${KEY_BITS}-bit RSA is required"
        return 1
    fi

    local csr_subject san
    csr_subject="$(openssl req -in "$csr" -noout -subject 2>/dev/null | sed 's/^subject= *//')"
    san="$(get_csr_san "$csr")"
    san="${san//IP Address:/IP:}"
    san="${san//, /,}"
    if [[ "$san" == *"<unsupported>"* || "$san" == *othername* ]]; then
        log_error "[$cn] CSR contains a Subject Alternative Name type this script cannot copy: $san"
        return 1
    fi
    log_info "[$cn] CSR subject : ${csr_subject}"
    log_info "[$cn] CSR SANs    : ${san:-none}"

    # ---- Output folder -----------------------------------------------------
    if [[ -d "$host_dir" ]]; then
        log_exists "Host folder already exists: $host_dir"
    elif mkdir -p "$host_dir" 2>/dev/null; then
        log_created "Host folder created: $host_dir"
    else
        log_error "[$cn] Unable to create folder: $host_dir"
        return 1
    fi
    if [[ ! -w "$host_dir" ]]; then
        log_error "[$cn] Folder is not writable: $host_dir"
        return 1
    fi

    # ---- Temporary config: profile gets the SANs from the CSR --------------
    # Only the SAN is injected into the profile section (replacing any SAN the
    # profile defines). Nothing else from the CSR's requested extensions is
    # copied, so the profile alone decides keyUsage / EKU / basicConstraints.
    local tmp_conf="${WORK_DIR}/${cn}.conf"
    local tmp_crt="${WORK_DIR}/${cn}.crt"
    local tmp_chain="${WORK_DIR}/${cn}.fullchain.crt"
    rm -f "$tmp_crt" "$tmp_chain"

    awk -v prof="$profile" -v san="$san" '
        /^[ \t]*\[/ {
            name = $0
            sub(/^[ \t]*\[[ \t]*/, "", name)
            sub(/[ \t]*\].*$/, "", name)
            in_prof = (name == prof)
            print
            if (in_prof && san != "") print "subjectAltName = " san
            next
        }
        in_prof && san != "" && /^[ \t]*subjectAltName[ \t]*=/ { next }
        { print }
    ' "$CA_CONF" > "$tmp_conf" || {
        log_error "[$cn] Unable to build temporary OpenSSL config"
        return 1
    }

    # ---- Sign --------------------------------------------------------------
    local -a days_args=()
    [[ -n "$CERT_DAYS" ]] && days_args=(-days "$CERT_DAYS")

    log_info "[$cn] Signing (${DIGEST}, CA key ${KEY_BITS}-bit) ..."
    local out rc
    out="$(cd "$CA_DIR" && openssl ca -batch -notext -preserveDN \
            -config "$tmp_conf" \
            -extensions "$profile" \
            -md "$DIGEST" \
            -keyfile "$CA_KEY" \
            -cert "$CA_CERT" \
            -in "$csr" \
            -out "$tmp_crt" \
            "${days_args[@]+"${days_args[@]}"}" \
            "${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"}" 2>&1)"
    rc=$?
    if (( rc != 0 )) || [[ ! -s "$tmp_crt" ]]; then
        log_error "[$cn] openssl ca failed (exit $rc)"
        log_output log_error "$out"
        return 1
    fi

    if ! openssl x509 -in "$tmp_crt" -noout >/dev/null 2>&1; then
        log_error "[$cn] openssl produced an unreadable certificate"
        return 1
    fi

    # Confirm the signature algorithm
    if ! openssl x509 -in "$tmp_crt" -noout -text | grep -q "Signature Algorithm: ${DIGEST}With"; then
        log_warn "[$cn] Certificate signature algorithm is not ${DIGEST}-based"
    fi

    # ---- Build full chain: issued certificate + root CA --------------------
    if ! { openssl x509 -in "$tmp_crt"; openssl x509 -in "$CA_CERT"; } > "$tmp_chain" 2>/dev/null; then
        log_error "[$cn] Failed to build the full chain file"
        return 1
    fi

    # ---- Install the files -------------------------------------------------
    if ! mv -n "$tmp_crt" "$crt" 2>/dev/null || [[ ! -s "$crt" ]]; then
        log_error "[$cn] Unable to write certificate: $crt"
        return 1
    fi
    chmod 644 "$crt"
    log_created "Certificate created: $crt"

    if ! mv -n "$tmp_chain" "$chain" 2>/dev/null || [[ ! -s "$chain" ]]; then
        log_error "[$cn] Unable to write full chain file: $chain"
        return 1
    fi
    chmod 644 "$chain"
    log_created "Full chain created: $chain"

    # ---- Post-checks and details -------------------------------------------
    if out="$(openssl verify -CAfile "$CA_CERT" "$crt" 2>&1)"; then
        log_ok "[$cn] Verified against root CA"
    else
        log_warn "[$cn] Verification against the root CA failed:"
        log_output log_warn "$out"
    fi

    local serial not_after
    serial="$(openssl x509 -in "$crt" -noout -serial | cut -d= -f2)"
    not_after="$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
    log_ok "Signed '$cn' [profile: $profile; serial: $serial; expires: $not_after]"

    export_p12 "$cn"
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
    if [[ ! -f "$SIGN_LIST" || ! -r "$SIGN_LIST" ]]; then
        log_error "Sign list not found or not readable: $SIGN_LIST"
        exit 2
    fi
    SIGN_LIST="$(readlink -f -- "$SIGN_LIST" 2>/dev/null || printf '%s' "$SIGN_LIST")"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sign_csr.XXXXXX")" || {
        log_error "Unable to create a temporary working directory"; exit 2; }

    log_info "Sign list       : $SIGN_LIST"
    log_info "CSR folder      : $CSR_DIR"
    log_info "Output base     : $HOST_BASE_DIR"
    log_info "CA config       : $CA_CONF"
    log_info "CA certificate  : $CA_CERT"
    log_info "OpenSSL         : $(openssl version)"

    if [[ ! -d "$CA_DIR" ]]; then
        log_error "CA folder not found: $CA_DIR"
        exit 2
    fi

    # The CA index and serial files must not be updated by two runs at once.
    if command -v flock >/dev/null 2>&1; then
        if { exec 9>"${CA_DIR}/.sign_csr.lock"; } 2>/dev/null; then
            if ! flock -n 9; then
                log_error "Another signing run is already in progress (lock: ${CA_DIR}/.sign_csr.lock)"
                exit 2
            fi
        else
            log_warn "Could not create lock file in $CA_DIR; continuing without a lock"
        fi
    fi

    check_ca || exit 2
    echo

    local lineno=0 total=0 signed=0 existing=0 failed=0 skipped=0
    local raw line cn profile extra rc

    while IFS= read -r raw <&3 || [[ -n "$raw" ]]; do
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

        # Strip a trailing inline comment
        line="$(trim "${line%%[[:space:]]#*}")"

        ((total++))
        IFS='|' read -r cn profile extra <<< "$line"
        cn="$(trim "${cn:-}")"
        profile="$(trim "${profile:-}")"

        if [[ -z "$cn" || -z "$profile" ]]; then
            log_error "Line $lineno: expected 'CN|extension_profile' -> '$line'"
            ((failed++)); echo; continue
        fi
        if [[ -n "${extra:-}" ]]; then
            log_error "Line $lineno [$cn]: too many fields (expected 2, separated by '|')"
            ((failed++)); echo; continue
        fi

        process_entry "$lineno" "$cn" "$profile"
        rc=$?
        case $rc in
            0) ((signed++)) ;;
            3) ((existing++)) ;;
            *) ((failed++)) ;;
        esac
        echo
    done 3< "$SIGN_LIST"

    log_info "------------------------------------------------------------"
    log_info "Summary: $total entr(ies) read - $signed signed, $existing skipped (certificate already exists), $failed failed, $skipped commented line(s) ignored"
    log_info "PKCS#12: $P12_CREATED created, $P12_EXISTS already existed, $P12_NOKEY skipped (no key/cert), $P12_FAILED failed"
    if (( total == 0 )); then
        log_warn "No entries found in $SIGN_LIST"
        exit 1
    fi
    (( failed == 0 && P12_FAILED == 0 )) || exit 1
    exit 0
}

main
