#!/usr/bin/env bash
# Fail if a requirement identifier written in square brackets appears in the repository or in
# generated output. Audit requirements are referred to by title only.
#
#   scripts/check-no-requirement-ids.sh [path ...]     default: the repository root
#
# A requirement identifier is a short upper-case family code, optionally a second code, then a
# number, optionally followed by enhancement or part numbers, all inside square brackets.
# Vendored content (collections/, roles/RHEL9-CIS/) and build output are skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
(( $# )) || set -- "$ROOT"

# Built from parts so this file doesn't match itself.
OPEN='\['
CLOSE='\]'
PATTERN="${OPEN}[A-Z]{1,10}(-[A-Z]{1,10})?[-.][0-9]{1,4}([.(][0-9a-z]{1,4}\)?)*${CLOSE}"

if grep -rInE "$PATTERN" "$@" \
     --exclude-dir=.git --exclude-dir=collections --exclude-dir=RHEL9-CIS \
     --exclude-dir=.terraform --exclude-dir=.terragrunt-cache --exclude-dir=out \
     --exclude-dir=.ansible; then
  echo "Requirement identifiers in square brackets found (refer to requirements by title only)." >&2
  exit 1
fi
echo "No requirement identifiers in square brackets."
