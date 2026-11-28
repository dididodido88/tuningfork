#!/usr/bin/env bash
#
# Script to safely initialize the OpenSSL Root CA directory, private key,
# and self-signed Root certificate with automated passphrase support and verification.
#
# The source openssl.cnf is expected to live in the same directory as this script
# and is copied into the CA directory before any key material is generated.
#
# ******
# Check or set $DOMAIN_NAME as an environment variable prior to running this script.
# ******
#

set -euo pipefail

# ------------------------------------------------------------------------------
# Text formatting & logging (defined first so every later step can use them)
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ------------------------------------------------------------------------------
# Configuration & Variable Definitions
# ------------------------------------------------------------------------------
if [[ -z "${DOMAIN_NAME:-}" ]]; then
    log_error "DOMAIN_NAME environment variable is not set."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG="${SCRIPT_DIR}/openssl.cnf"   # Source openssl.cnf alongside this script

CERT_DIR="/srv/security/certificates/files/$DOMAIN_NAME"
CA_DIR="${CERT_DIR}/ca"
CONFIG_FILE="${CA_DIR}/openssl.cnf"         # Destination copy used by the CA
PRIVATE_KEY="${CA_DIR}/private/ca.key.pem"
ROOT_CERT="${CA_DIR}/ca.cert.pem"
INDEX_FILE="${CA_DIR}/index.txt"
SERIAL_FILE="${CA_DIR}/serial"
DAYS_VALID=7390  # 20 years and 3 months
JKS_FILE="${CA_DIR}/ca.jks"
JKS_ALIAS="root-ca"
JKS_PASS="${JKS_PASS:-changeit}"  # Defaults to Java standard 'changeit'

# Passphrase handling:
# 1. Environment variable: CA_PASSPHRASE
# 2. Key file: CA_PASS_FILE (path to a file containing the passphrase)
CA_PASS_FILE="${CA_PASS_FILE:-}"
CA_PASSPHRASE="${CA_PASSPHRASE:-}"

# ------------------------------------------------------------------------------
# Passphrase Source Resolution
# ------------------------------------------------------------------------------
PASS_ARG=()

if [[ -n "$CA_PASSPHRASE" ]]; then
    log_info "Using passphrase provided via CA_PASSPHRASE environment variable."
    PASS_ARG=(-passout "env:CA_PASSPHRASE" -passin "env:CA_PASSPHRASE")
elif [[ -n "$CA_PASS_FILE" && -f "$CA_PASS_FILE" ]]; then
    log_info "Using passphrase provided via file: ${CA_PASS_FILE}"
    PASS_ARG=(-passout "file:${CA_PASS_FILE}" -passin "file:${CA_PASS_FILE}")
else
    log_warn "No automated passphrase defined. OpenSSL will prompt interactively."
fi

# ------------------------------------------------------------------------------
# Pre-flight Checks & Safety Guards
# ------------------------------------------------------------------------------

for cmd in openssl chmod touch mkdir cmp cp; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

# keytool ships with the Java JDK/JRE and is needed to build the Java KeyStore.
if ! command -v keytool &>/dev/null; then
    log_error "Required command 'keytool' is not installed or not in PATH."
    log_error "Install a Java runtime that includes keytool, e.g.:"
    log_error "dnf install -y java-latest-openjdk-headless"
    exit 1
fi

# The SOURCE config must exist next to this script...
if [[ ! -f "$SOURCE_CONFIG" ]]; then
    log_error "Source OpenSSL configuration file not found at: ${SOURCE_CONFIG}"
    exit 1
fi

# ...and nothing from a previous run may already exist in the CA directory.
EXISTING_FILES=()
for f in "$CONFIG_FILE" "$PRIVATE_KEY" "$ROOT_CERT" "$INDEX_FILE" "$SERIAL_FILE" "$JKS_FILE"; do
    [[ -e "$f" ]] && EXISTING_FILES+=("$f")
done

if [[ ${#EXISTING_FILES[@]} -gt 0 ]]; then
    log_error "Initialization aborted! Existing CA files detected:"
    for file in "${EXISTING_FILES[@]}"; do
        echo "  - ${file}"
    done
    log_error "Refusing to overwrite existing files. Exiting."
    exit 1
fi

# ------------------------------------------------------------------------------
# Directory Structure & Configuration Setup
# ------------------------------------------------------------------------------
log_info "Preparing CA directory structure at: ${CA_DIR}"

mkdir -p "${CA_DIR}"/{certs,crl,newcerts,private}
chmod 700 "${CA_DIR}/private"

for d in "$CA_DIR" "${CA_DIR}/certs" "${CA_DIR}/crl" "${CA_DIR}/newcerts" "${CA_DIR}/private"; do
    if [[ ! -d "$d" ]]; then
        log_error "Required directory could not be created: ${d}"
        exit 1
    fi
done

# Copy the source config into place (-n: never clobber) and verify the copy.
log_info "Copying ${SOURCE_CONFIG} to ${CONFIG_FILE}"
if ! cp -n "$SOURCE_CONFIG" "$CONFIG_FILE"; then
    log_error "Failed to copy openssl.cnf into ${CA_DIR}."
    exit 1
fi
if ! cmp -s "$SOURCE_CONFIG" "$CONFIG_FILE"; then
    log_error "Copied openssl.cnf does not match the source file."
    exit 1
fi
chmod 644 "$CONFIG_FILE"
log_info "OpenSSL configuration in place and verified."

# Database files (guaranteed not to exist by the pre-flight check above)
touch "$INDEX_FILE"
echo "1000" > "$SERIAL_FILE"

# ------------------------------------------------------------------------------
# Core Execution
# ------------------------------------------------------------------------------

log_info "Starting Root CA initialization at: ${CA_DIR}"

# 1. Generate 4096-bit RSA Private Key
log_info "Generating 4096-bit RSA Private Key..."
GENRSA_CMD=(openssl genrsa -aes256)
if [[ ${#PASS_ARG[@]} -gt 0 ]]; then
    GENRSA_CMD+=("${PASS_ARG[0]}" "${PASS_ARG[1]}")
fi
GENRSA_CMD+=(-out "$PRIVATE_KEY" 4096)

if "${GENRSA_CMD[@]}"; then
    chmod 400 "$PRIVATE_KEY"
    log_info "Private key generated successfully."
else
    log_error "Failed to generate private key."
    exit 1
fi

# 2. Generate Self-Signed Root Certificate
log_info "Generating self-signed Root CA certificate (20 years)..."
REQ_CMD=(openssl req -config "$CONFIG_FILE" \
    -key "$PRIVATE_KEY" \
    -new -x509 \
    -batch \
    -days "$DAYS_VALID" \
    -sha256 \
    -extensions v3_ca)

if [[ ${#PASS_ARG[@]} -gt 0 ]]; then
    REQ_CMD+=("${PASS_ARG[2]}" "${PASS_ARG[3]}")
fi
REQ_CMD+=(-out "$ROOT_CERT")

if "${REQ_CMD[@]}"; then
    chmod 444 "$ROOT_CERT"
    log_info "Root CA certificate generated successfully."
else
    log_error "Failed to generate Root CA certificate."
    exit 1
fi

# ------------------------------------------------------------------------------
# Automated Verification Checks
# ------------------------------------------------------------------------------
log_info "Performing integrity and cryptographic pair verification..."

KEY_MOD=$(openssl rsa -noout -modulus -in "$PRIVATE_KEY" "${PASS_ARG[@]:+${PASS_ARG[2]}}" "${PASS_ARG[@]:+${PASS_ARG[3]}}" | sha256sum)
CERT_MOD=$(openssl x509 -noout -modulus -in "$ROOT_CERT" | sha256sum)

if [[ "$KEY_MOD" != "$CERT_MOD" ]]; then
    log_error "CRITICAL: Private key modulus does not match Root certificate modulus!"
    exit 1
fi
log_info "PASS: Private key and Root certificate public key match."

if openssl verify -CAfile "$ROOT_CERT" "$ROOT_CERT" &>/dev/null; then
    log_info "PASS: Certificate self-signature is valid."
else
    log_error "CRITICAL: Certificate self-signature verification failed."
    exit 1
fi

# ------------------------------------------------------------------------------
# Java KeyStore Creation
# ------------------------------------------------------------------------------
log_info "Creating Java KeyStore containing the Root CA certificate..."

if keytool -importcert -noprompt -trustcacerts \
    -alias "$JKS_ALIAS" \
    -file "$ROOT_CERT" \
    -keystore "$JKS_FILE" \
    -storepass "$JKS_PASS" \
    -storetype PKCS12; then

    chmod 644 "$JKS_FILE"
    log_info "Java KeyStore successfully created at: ${JKS_FILE}"
else
    log_error "Failed to create Java KeyStore."
    exit 1
fi

# ------------------------------------------------------------------------------
# Verification & Keystore Output
# ------------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo -e "${GREEN}Verifying Java KeyStore Contents:${NC}"
echo "=========================================================================="
keytool -list -v -keystore "$JKS_FILE" -storepass "$JKS_PASS"

echo ""
echo "=========================================================================="
echo -e "${GREEN}Root CA Initialized & Verified Successfully!${NC}"
echo "=========================================================================="
echo "Generated Artifacts:"
echo "  - Key:      ${PRIVATE_KEY} (Mode: 0400)"
echo "  - Cert:     ${ROOT_CERT} (Mode: 0444)"
echo "  - Config:   ${CONFIG_FILE} (copied from ${SOURCE_CONFIG})"
echo "  - DB/Index: ${INDEX_FILE}"
echo "  - Serial:   ${SERIAL_FILE}"
echo "  - Keystore: ${JKS_FILE} (Mode: 0644, Alias: ${JKS_ALIAS})"
echo "=========================================================================="
