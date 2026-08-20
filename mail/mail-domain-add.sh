#!/bin/bash
# lazy-admin-tools: Add a canonical mail domain
# Usage: mail-domain-add <domain>

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: mail-domain-add <domain>" >&2
	exit 2
fi

DOMAIN="$1"

# Rough domain syntax check: labels of alphanumerics/hyphens separated
# by dots, no leading/trailing hyphen per label, at least one dot.
if ! [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
	echo "[ERROR] not a valid domain: $DOMAIN" >&2
	exit 1
fi

if [[ ! -f "$BASE/domains" ]]; then
	echo "[ERROR] $BASE/domains not found - run mailserver-init first" >&2
	exit 1
fi

if grep -qxF "$DOMAIN" "$BASE/domains"; then
	echo "[ERROR] domain already exists: $DOMAIN" >&2
	exit 1
fi

if awk -v d="$DOMAIN" '$1==d' "$BASE/domain-aliases" | grep -q .; then
	echo "[ERROR] domain is already configured as an alias: $DOMAIN" >&2
	exit 1
fi

# Atomic write: append via temp file + rename, not in-place >>
TMP=$(mktemp "$BASE/.domains.XXXXXX")
cp -p "$BASE/domains" "$TMP"
echo "$DOMAIN" >> "$TMP"
mv "$TMP" "$BASE/domains"

echo "[OK] domain added: $DOMAIN"
