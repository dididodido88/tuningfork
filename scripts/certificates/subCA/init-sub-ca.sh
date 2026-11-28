#!/usr/bin/env bash
#
# init-sub-ca.sh - Create a subordinate (issuing) CA signed by the environment's root CA,
# for cert-manager's CA ClusterIssuer on a Kubernetes cluster.
#
# The root's key never leaves maestro: the cluster gets this sub-CA instead. The sub-CA can sign
# only leaf certificates (pathlen 0), only for the permitted DNS domains (name constraints), and
# only for server and client authentication (extended key usage). If it leaks, only the sub-CA
# is replaced; the root and every host certificate stay valid.
#
# Reads (created by rootCA/init-root.ca.sh):
#   /srv/security/certificates/files/<DOMAIN_NAME>/ca/ca.cert.pem
#   /srv/security/certificates/files/<DOMAIN_NAME>/ca/private/ca.key.pem   (encrypted)
#   /srv/security/certificates/files/<DOMAIN_NAME>/ca/openssl.cnf          (index.txt, serial)
#
# Writes (never overwrites anything; a second run refuses):
#   /srv/security/certificates/files/<DOMAIN_NAME>/<SUBCA_NAME>/<SUBCA_NAME>.key            0600, UNENCRYPTED
#   /srv/security/certificates/files/<DOMAIN_NAME>/<SUBCA_NAME>/<SUBCA_NAME>.crt            0644
#   /srv/security/certificates/files/<DOMAIN_NAME>/<SUBCA_NAME>/<SUBCA_NAME>.fullchain.crt  0644 (sub-CA + root)
# The key is unencrypted because cert-manager needs a plain key in its Kubernetes Secret. Keep it
# as protected as the root key's passphrase.
#
# The issuance is recorded in the root CA's database (index.txt, serial), like every host
# certificate signed by host/sign.sh, and uses the same lock file, so the two never run at once.
#
# Usage:
#   DOMAIN_NAME=lab.local ./init-sub-ca.sh
#
# Environment:
#   DOMAIN_NAME     required, e.g. lab.local (the folder under /srv/security/certificates/files)
#   SUBCA_NAME      folder and file name, default app-cluster-ca
#   SUBCA_CN        subject common name, default "<SUBCA_NAME> cert-manager issuing CA"
#   SUBCA_DAYS      validity in days, default 3650 (10 years); capped at the root's expiry
#   PERMITTED_DNS   comma-separated DNS domains the sub-CA may issue for (each covers its
#                   subdomains), default "<DOMAIN_NAME>,cluster.local,svc"
#   CA_PASSPHRASE   the root key's passphrase (passed to openssl as env:, never on the command
#                   line); or CA_PASS_FILE, a file holding it; otherwise you are prompted once
#   CERT_BASE_DIR, CA_DIR, CA_CONF, CA_KEY, CA_CERT   relocate the paths above
#
# The subject's C, ST and O are copied from the root certificate, as the root's policy_strict
# requires; CN is SUBCA_CN.
#
# Renewal: run again with a new SUBCA_NAME (e.g. app-cluster-ca-2029; the root's database refuses
# a second certificate with the same subject), then point the Terraform unit at the new folder.

set -uo pipefail
umask 077

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
if [[ -z "${DOMAIN_NAME:-}" ]]; then
    echo "[ERROR] DOMAIN_NAME environment variable is not set (e.g. DOMAIN_NAME=lab.local)." >&2
    exit 2
fi

SUBCA_NAME="${SUBCA_NAME:-app-cluster-ca}"
SUBCA_CN="${SUBCA_CN:-${SUBCA_NAME} cert-manager issuing CA}"
SUBCA_DAYS="${SUBCA_DAYS:-3650}"
PERMITTED_DNS="${PERMITTED_DNS:-${DOMAIN_NAME},cluster.local,svc}"

CERT_BASE_DIR="${CERT_BASE_DIR:-/srv/security/certificates/files/$DOMAIN_NAME}"
CA_DIR="${CA_DIR:-${CERT_BASE_DIR}/ca}"
CA_CONF="${CA_CONF:-${CA_DIR}/openssl.cnf}"
CA_KEY="${CA_KEY:-${CA_DIR}/private/ca.key.pem}"
CA_CERT="${CA_CERT:-${CA_DIR}/ca.cert.pem}"

OUT_DIR="${CERT_BASE_DIR}/${SUBCA_NAME}"
OUT_KEY="${OUT_DIR}/${SUBCA_NAME}.key"
OUT_CRT="${OUT_DIR}/${SUBCA_NAME}.crt"
OUT_CHAIN="${OUT_DIR}/${SUBCA_NAME}.fullchain.crt"

KEY_BITS=4096
DIGEST="sha256"
EXT_SECTION="v3_k8s_subca"
BAD_RE='[$"\\]'   # characters that would break the generated OpenSSL config ($ " \)

# ----------------------------------------------------------------------------
# Logging helpers (as in host/sign.sh)
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

log_output() {  # log_output LEVEL_FUNC TEXT
    local fn="$1" text="$2" l
    while IFS= read -r l; do
        [[ -n "$l" ]] && "$fn" "    openssl: $l"
    done <<< "$text"
}

# ----------------------------------------------------------------------------
# Utility functions
# ----------------------------------------------------------------------------
WORK_DIR=""
cleanup() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
    unset CA_PASSPHRASE 2>/dev/null || true
}
trap cleanup EXIT
trap 'log_error "Interrupted."; exit 130' INT TERM

trim() {
    local s="${1//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
is_valid_dns()  { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

# Extract "NNNN" from "(NNNN bit" in openssl text output on stdin.
parse_bits() { grep -oE '\([0-9]+ bit' | head -n1 | tr -dc '0-9'; }

# One attribute (C, ST, O, ...) of the root certificate's subject.
root_subject_attr() {
    openssl x509 -in "$CA_CERT" -noout -subject -nameopt sep_multiline,sname,utf8 2>/dev/null |
        awk -v k="$1" '{ sub(/^[ \t]+/, "") } index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

# ----------------------------------------------------------------------------
# Root CA passphrase (once, up front; as in host/sign.sh)
# ----------------------------------------------------------------------------
PASSIN_ARGS=()
setup_passin() {
    if [[ -n "${CA_PASSPHRASE:-}" ]]; then
        :
    elif [[ -n "${CA_PASS_FILE:-}" ]]; then
        if [[ ! -r "$CA_PASS_FILE" ]]; then
            log_error "CA_PASS_FILE is not readable: $CA_PASS_FILE"
            return 1
        fi
        PASSIN_ARGS=(-passin "file:${CA_PASS_FILE}")
        return 0
    elif grep -q "ENCRYPTED" "$CA_KEY" 2>/dev/null; then
        if [[ -t 0 && -t 2 ]]; then
            read -r -s -p "Enter passphrase for root CA key ${CA_KEY}: " CA_PASSPHRASE
            echo >&2
        else
            log_error "Root CA key is encrypted and no terminal is available. Set CA_PASSPHRASE or CA_PASS_FILE."
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

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
check_inputs() {
    local ok=0 d

    if ! is_valid_name "$SUBCA_NAME"; then
        log_error "SUBCA_NAME '$SUBCA_NAME' is invalid (allowed: letters, digits, '.', '_', '-')"
        ok=1
    fi
    if [[ -z "$SUBCA_CN" || "$SUBCA_CN" =~ $BAD_RE ]]; then
        log_error "SUBCA_CN is empty or contains an unsupported character (\$ \" or \\)"
        ok=1
    fi
    if ! [[ "$SUBCA_DAYS" =~ ^[0-9]+$ ]] || (( SUBCA_DAYS < 1 )); then
        log_error "SUBCA_DAYS must be a positive number of days (got '$SUBCA_DAYS')"
        ok=1
    fi

    PERMITTED=()
    local -a items
    IFS=',' read -r -a items <<< "$PERMITTED_DNS"
    for d in "${items[@]}"; do
        d="$(trim "$d")"
        [[ -z "$d" ]] && continue
        if is_valid_dns "$d"; then
            PERMITTED+=("$d")
        else
            log_error "PERMITTED_DNS entry '$d' is not a valid DNS domain"
            ok=1
        fi
    done
    if (( ${#PERMITTED[@]} == 0 )); then
        log_error "PERMITTED_DNS lists no domain; the sub-CA must be name-constrained"
        ok=1
    fi
    return $ok
}

check_ca() {
    local f
    for f in "$CA_CONF" "$CA_KEY" "$CA_CERT"; do
        if [[ ! -r "$f" ]]; then
            log_error "Required root CA file not found or not readable: $f"
            return 1
        fi
    done
    for f in "${CA_DIR}/index.txt" "${CA_DIR}/serial"; do
        if [[ ! -w "$f" ]]; then
            log_error "Root CA database file missing or not writable: $f"
            return 1
        fi
    done

    setup_passin || return 1

    local bits
    bits="$(openssl rsa -in "$CA_KEY" -noout -text "${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"}" 2>/dev/null | parse_bits)"
    if [[ -z "$bits" ]]; then
        log_error "Unable to read the root CA key (wrong passphrase or not an RSA key): $CA_KEY"
        return 1
    fi

    if ! openssl x509 -in "$CA_CERT" -noout -checkend 0 >/dev/null 2>&1; then
        log_error "Root CA certificate has expired: $CA_CERT"
        return 1
    fi
    local pub_key pub_cert
    pub_key="$(openssl pkey -in "$CA_KEY" -pubout "${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"}" 2>/dev/null)"
    pub_cert="$(openssl x509 -in "$CA_CERT" -noout -pubkey 2>/dev/null)"
    if [[ -z "$pub_key" || "$pub_key" != "$pub_cert" ]]; then
        log_error "Root CA key does not match the root certificate ($CA_KEY vs $CA_CERT)"
        return 1
    fi

    log_ok "Root CA verified: ${bits}-bit RSA key matches $(openssl x509 -in "$CA_CERT" -noout -subject | sed 's/^subject= *//')"
    return 0
}

# A sub-CA must not outlive its root: shorten SUBCA_DAYS to the root's remaining days.
cap_days() {
    local root_end root_epoch now left
    root_end="$(openssl x509 -in "$CA_CERT" -noout -enddate | cut -d= -f2)"
    if ! root_epoch="$(date -d "$root_end" +%s 2>/dev/null)"; then
        log_warn "Cannot read the root's expiry ($root_end); not checking SUBCA_DAYS against it"
        return 0
    fi
    now="$(date +%s)"
    left=$(( (root_epoch - now) / 86400 - 1 ))
    if (( SUBCA_DAYS > left )); then
        log_warn "SUBCA_DAYS ${SUBCA_DAYS} would outlive the root (expires ${root_end}); using ${left} days"
        SUBCA_DAYS="$left"
    fi
    return 0
}

check_outputs() {
    local f found=0
    for f in "$OUT_KEY" "$OUT_CRT" "$OUT_CHAIN"; do
        if [[ -e "$f" ]]; then
            log_error "Already exists, NOT overwriting: $f"
            found=1
        fi
    done
    if (( found )); then
        log_error "Use a new SUBCA_NAME to create another sub-CA, or move the old folder aside."
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    local cmd
    for cmd in openssl awk grep sed date mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' is not installed or not in PATH."
            exit 2
        fi
    done

    log_info "Root CA folder  : $CA_DIR"
    log_info "Sub-CA          : $SUBCA_NAME (CN \"$SUBCA_CN\")"
    log_info "Output folder   : $OUT_DIR"
    log_info "OpenSSL         : $(openssl version)"

    check_inputs || exit 2
    log_info "Permitted DNS   : ${PERMITTED[*]}"

    if [[ ! -d "$CA_DIR" ]]; then
        log_error "Root CA folder not found: $CA_DIR"
        exit 2
    fi

    # The root's index.txt and serial must not be updated by two runs at once (same lock as host/sign.sh).
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

    check_outputs || exit 1
    check_ca || exit 2
    cap_days
    log_info "Validity        : ${SUBCA_DAYS} days"

    # Subject: C, ST and O must match the root (policy_strict).
    local c st o
    c="$(root_subject_attr C)"; st="$(root_subject_attr ST)"; o="$(root_subject_attr O)"
    if [[ -z "$c" || -z "$st" || -z "$o" ]]; then
        log_error "Cannot read C, ST and O from the root's subject; policy_strict needs all three"
        exit 2
    fi
    if [[ "$c$st$o" =~ $BAD_RE ]]; then
        log_error "The root's subject contains a character this script cannot copy (\$ \" or \\)"
        exit 2
    fi
    log_info "Subject         : C=${c}, ST=${st}, O=${o}, CN=${SUBCA_CN}"

    # Work in a root-only folder on the same file system, so the key never lands in /tmp.
    if [[ -d "$OUT_DIR" ]]; then
        log_exists "Output folder already exists: $OUT_DIR"
    elif mkdir -p "$OUT_DIR"; then
        log_created "Output folder created: $OUT_DIR"
    else
        log_error "Unable to create folder: $OUT_DIR"
        exit 1
    fi
    WORK_DIR="$(mktemp -d "${OUT_DIR}/.init-sub-ca.XXXXXX")" || {
        log_error "Unable to create a temporary folder in $OUT_DIR"; exit 1; }

    local key="${WORK_DIR}/subca.key" csr="${WORK_DIR}/subca.csr" crt="${WORK_DIR}/subca.crt"
    local chain="${WORK_DIR}/subca.fullchain.crt" req_conf="${WORK_DIR}/req.cnf" ext="${WORK_DIR}/ext.cnf"
    local out rc d

    # ---- Key (unencrypted: cert-manager reads it from a Secret) ---------------
    log_info "Generating RSA ${KEY_BITS}-bit private key ..."
    if ! out="$(openssl genrsa -out "$key" "$KEY_BITS" 2>&1)"; then
        log_error "Failed to generate the private key"
        log_output log_error "$out"
        exit 1
    fi
    chmod 600 "$key"

    # ---- CSR ------------------------------------------------------------------
    {
        echo "[ req ]"
        echo "default_md         = ${DIGEST}"
        echo "prompt             = no"
        echo "string_mask        = utf8only"
        echo "utf8               = yes"
        echo "distinguished_name = req_dn"
        echo
        echo "[ req_dn ]"
        printf 'C  = "%s"\n'  "$c"
        printf 'ST = "%s"\n'  "$st"
        printf 'O  = "%s"\n'  "$o"
        printf 'CN = "%s"\n'  "$SUBCA_CN"
    } > "$req_conf"
    if ! out="$(openssl req -new -key "$key" -config "$req_conf" -out "$csr" 2>&1)"; then
        log_error "Failed to generate the CSR"
        log_output log_error "$out"
        exit 1
    fi

    # ---- Extensions of the sub-CA ----------------------------------------------
    # Generated here: the root's openssl.cnf in the CA folder is a copy made at root init.
    local nc="critical"
    for d in "${PERMITTED[@]}"; do nc+=", permitted;DNS:${d}"; done
    {
        echo "[ ${EXT_SECTION} ]"
        echo "subjectKeyIdentifier   = hash"
        echo "authorityKeyIdentifier = keyid:always,issuer"
        echo "basicConstraints       = critical, CA:true, pathlen:0"
        echo "keyUsage               = critical, digitalSignature, cRLSign, keyCertSign"
        echo "extendedKeyUsage       = serverAuth, clientAuth"
        echo "nameConstraints        = ${nc}"
    } > "$ext"

    # ---- Sign with the root (recorded in index.txt and serial) ----------------
    log_info "Signing with the root CA (${DIGEST}, ${SUBCA_DAYS} days) ..."
    out="$(cd "$CA_DIR" && openssl ca -batch -notext -preserveDN \
            -config "$CA_CONF" \
            -extfile "$ext" \
            -extensions "$EXT_SECTION" \
            -md "$DIGEST" \
            -days "$SUBCA_DAYS" \
            -keyfile "$CA_KEY" \
            -cert "$CA_CERT" \
            -in "$csr" \
            -out "$crt" \
            "${PASSIN_ARGS[@]+"${PASSIN_ARGS[@]}"}" 2>&1)"
    rc=$?
    if (( rc != 0 )) || [[ ! -s "$crt" ]]; then
        log_error "openssl ca failed (exit $rc)"
        log_output log_error "$out"
        exit 1
    fi

    # ---- Checks -----------------------------------------------------------------
    local text pub_key pub_crt failed=0
    pub_key="$(openssl pkey -in "$key" -pubout 2>/dev/null)"
    pub_crt="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)"
    if [[ -z "$pub_key" || "$pub_key" != "$pub_crt" ]]; then
        log_error "The signed certificate does not match the generated key"
        failed=1
    fi
    if ! out="$(openssl verify -CAfile "$CA_CERT" "$crt" 2>&1)"; then
        log_error "The sub-CA does not verify against the root:"
        log_output log_error "$out"
        failed=1
    fi
    text="$(openssl x509 -in "$crt" -noout -text 2>/dev/null)"
    if ! grep -q "CA:TRUE, pathlen:0" <<< "$text"; then
        log_error "Basic constraints are not CA:TRUE, pathlen:0"
        failed=1
    fi
    if ! grep -q "X509v3 Name Constraints: critical" <<< "$text"; then
        log_error "Name constraints are missing or not critical"
        failed=1
    fi
    for d in "${PERMITTED[@]}"; do
        if ! grep -qE "^[[:space:]]+DNS:${d//./\\.}$" <<< "$text"; then
            log_error "Permitted name DNS:${d} is missing from the name constraints"
            failed=1
        fi
    done
    if (( failed )); then
        log_error "Checks failed; nothing was installed (the root's database records the issuance)."
        exit 1
    fi
    log_ok "Key matches; chains to the root; CA:TRUE, pathlen:0; name constraints in place"

    # ---- Install the files (never overwrite) -----------------------------------
    if ! { openssl x509 -in "$crt"; openssl x509 -in "$CA_CERT"; } > "$chain" 2>/dev/null; then
        log_error "Failed to build the full chain file"
        exit 1
    fi
    chmod 644 "$crt" "$chain"

    if ! mv -n "$key" "$OUT_KEY" || [[ -e "$key" ]]; then
        log_error "Unable to install the key: $OUT_KEY"; exit 1
    fi
    log_created "Private key created: $OUT_KEY (0600, unencrypted)"
    if ! mv -n "$crt" "$OUT_CRT" || [[ -e "$crt" ]]; then
        log_error "Unable to install the certificate: $OUT_CRT"; exit 1
    fi
    log_created "Certificate created: $OUT_CRT"
    if ! mv -n "$chain" "$OUT_CHAIN" || [[ -e "$chain" ]]; then
        log_error "Unable to install the full chain: $OUT_CHAIN"; exit 1
    fi
    log_created "Full chain created: $OUT_CHAIN"

    local serial not_after
    serial="$(openssl x509 -in "$OUT_CRT" -noout -serial | cut -d= -f2)"
    not_after="$(openssl x509 -in "$OUT_CRT" -noout -enddate | cut -d= -f2)"
    echo
    echo "=========================================================================="
    echo "Sub-CA created and verified: ${SUBCA_NAME}"
    echo "=========================================================================="
    echo "  Subject   : C=${c}, ST=${st}, O=${o}, CN=${SUBCA_CN}"
    echo "  Serial    : ${serial}"
    echo "  Expires   : ${not_after}"
    echo "  Permitted : ${PERMITTED[*]}"
    echo "  Key       : ${OUT_KEY} (0600, unencrypted)"
    echo "  Cert      : ${OUT_CRT}"
    echo "  Chain     : ${OUT_CHAIN} (sub-CA + root)"
    echo "=========================================================================="
    exit 0
}

main
