#!/bin/bash
# lazy-admin-tools: Add an alias domain pointing to a canonical domain
# Usage: mail-domain-alias-add <alias-domain> <canonical-domain>

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

if [[ $# -ne 2 ]]; then
	echo "Usage: mail-domain-alias-add <alias-domain> <canonical-domain>" >&2
	exit 2
fi

ALIAS_DOMAIN="$1"
CANONICAL_DOMAIN="$2"

for f in domains domain-aliases; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

if ! [[ "$ALIAS_DOMAIN" =~ $DOMAIN_RE ]]; then
	echo "[ERROR] not a valid domain: $ALIAS_DOMAIN" >&2
	exit 1
fi

if ! [[ "$CANONICAL_DOMAIN" =~ $DOMAIN_RE ]]; then
	echo "[ERROR] not a valid domain: $CANONICAL_DOMAIN" >&2
	exit 1
fi

if [[ "$ALIAS_DOMAIN" == "$CANONICAL_DOMAIN" ]]; then
	echo "[ERROR] alias domain must differ from canonical domain: $ALIAS_DOMAIN" >&2
	exit 1
fi

if grep -qxF "$ALIAS_DOMAIN" "$BASE/domains"; then
	echo "[ERROR] domain is already configured as canonical: $ALIAS_DOMAIN" >&2
	exit 1
fi

if awk -v d="$ALIAS_DOMAIN" '$1==d' "$BASE/domain-aliases" | grep -q .; then
	echo "[ERROR] alias domain already exists: $ALIAS_DOMAIN" >&2
	exit 1
fi

if ! grep -qxF "$CANONICAL_DOMAIN" "$BASE/domains"; then
	echo "[ERROR] canonical domain does not exist: $CANONICAL_DOMAIN" >&2
	exit 1
fi

TMP=$(mktemp "$BASE/.domain-aliases.XXXXXX")
cp -p "$BASE/domain-aliases" "$TMP"
echo "$ALIAS_DOMAIN $CANONICAL_DOMAIN" >> "$TMP"
mv "$TMP" "$BASE/domain-aliases"

echo "[OK] alias domain added: $ALIAS_DOMAIN -> $CANONICAL_DOMAIN"
