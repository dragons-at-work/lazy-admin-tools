#!/bin/bash
# lazy-admin-tools: Remove a mail alias
# Usage: mail-alias-del <alias-address>

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
	echo "Usage: mail-alias-del <alias-address>" >&2
	exit 2
fi

ALIAS_ADDRESS="$1"

if [[ ! -f "$BASE/aliases" ]]; then
	echo "[ERROR] $BASE/aliases not found - run mailserver-init first" >&2
	exit 1
fi

if ! awk -v a="$ALIAS_ADDRESS" '$1==a' "$BASE/aliases" | grep -q .; then
	echo "[ERROR] alias does not exist: $ALIAS_ADDRESS" >&2
	exit 1
fi

ORIG_MODE=$(stat -c '%a' "$BASE/aliases")
ORIG_OWNER=$(stat -c '%U:%G' "$BASE/aliases")

TMP=$(mktemp "$BASE/.aliases.XXXXXX")
awk -v a="$ALIAS_ADDRESS" '$1!=a' "$BASE/aliases" > "$TMP"
chmod "$ORIG_MODE" "$TMP"
chown "$ORIG_OWNER" "$TMP"
mv "$TMP" "$BASE/aliases"

echo "[OK] alias removed: $ALIAS_ADDRESS"
echo ""
echo "-- lazy-admin-tools - dragons@work"
