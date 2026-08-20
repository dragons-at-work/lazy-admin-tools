#!/bin/bash
# lazy-admin-tools: Remove an alias domain
# Usage: mail-domain-alias-del <alias-domain>

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
	echo "Usage: mail-domain-alias-del <alias-domain>" >&2
	exit 2
fi

ALIAS_DOMAIN="$1"

if [[ ! -f "$BASE/domain-aliases" ]]; then
	echo "[ERROR] $BASE/domain-aliases not found - run mailserver-init first" >&2
	exit 1
fi

if ! awk -v d="$ALIAS_DOMAIN" '$1==d' "$BASE/domain-aliases" | grep -q .; then
	echo "[ERROR] alias domain does not exist: $ALIAS_DOMAIN" >&2
	exit 1
fi

ORIG_MODE=$(stat -c '%a' "$BASE/domain-aliases")
ORIG_OWNER=$(stat -c '%U:%G' "$BASE/domain-aliases")

TMP=$(mktemp "$BASE/.domain-aliases.XXXXXX")
awk -v d="$ALIAS_DOMAIN" '$1!=d' "$BASE/domain-aliases" > "$TMP"
chmod "$ORIG_MODE" "$TMP"
chown "$ORIG_OWNER" "$TMP"
mv "$TMP" "$BASE/domain-aliases"

echo "[OK] alias domain removed: $ALIAS_DOMAIN"
echo ""
echo "-- lazy-admin-tools - dragons@work"
