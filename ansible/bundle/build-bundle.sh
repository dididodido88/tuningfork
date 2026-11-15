#!/usr/bin/env bash
# Build the SIEM artifact bundle on an internet-connected staging machine (Linux).
#
#   bundle/build-bundle.sh <ENV>          e.g. bundle/build-bundle.sh lab
#
# Reads ansible/inventories/<ENV>/group_vars/all/siem_versions.yml and writes
# ansible/bundle/out/siem-bundle-<ENV>-<date>/ (see bundle/build-bundle.yml and docs/siem.md).
#
# Needs: ansible-core (2.14+), python3 with pip and venv, curl, tar, sha256sum, net-snmp's MIB
# files (/usr/share/snmp/mibs) and podman or docker (for the snmp_exporter generator; set
# BUNDLE_CONTAINER_RUNTIME=docker to use docker). The Dell iDRAC MIB must be in bundle/manual/.
set -euo pipefail

ENV_NAME="${1:-}"
if [[ -z "$ENV_NAME" ]]; then
  echo "usage: $0 <ENV>   (one of: $(ls "$(dirname "$0")/../inventories" | tr '\n' ' '))" >&2
  exit 2
fi

ANSIBLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="$ANSIBLE_DIR/inventories/$ENV_NAME/group_vars/all/siem_versions.yml"
[[ -f "$VERSIONS" ]] || { echo "No $VERSIONS" >&2; exit 2; }

missing=()
for cmd in ansible-playbook python3 curl tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
python3 -m pip --version >/dev/null 2>&1 || missing+=("python3-pip")
python3 -c 'import venv' >/dev/null 2>&1 || missing+=("python3 venv")
[[ -d /usr/share/snmp/mibs ]] || missing+=("net-snmp MIBs (/usr/share/snmp/mibs)")
runtime="${BUNDLE_CONTAINER_RUNTIME:-podman}"
command -v "$runtime" >/dev/null 2>&1 || echo "Note: $runtime not found; needed only if the stock snmp.yml has no iDRAC module." >&2
if (( ${#missing[@]} )); then
  echo "Missing prerequisites: ${missing[*]}" >&2
  exit 2
fi

# Own config: no inventory, no vault (the repo's ansible.cfg expects a vault password file).
export ANSIBLE_CONFIG="$ANSIBLE_DIR/bundle/ansible.cfg"
exec ansible-playbook -i localhost, "$ANSIBLE_DIR/bundle/build-bundle.yml" -e "bundle_env=$ENV_NAME" "${@:2}"
