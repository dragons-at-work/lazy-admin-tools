#!/bin/bash
# lazy-admin-tools: Add a mail alias
# Usage: mail-alias-add <alias-address> <target-address>
#
# Target must be either an existing local mailbox or an address outside
# our managed canonical domains. Alias-to-alias chains are not
# supported in this version - target resolution stays flat.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
LOCALPART_RE='^[a-zA-Z0-9._%+-]+$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

if [[ $# -ne 2 ]]; then
	echo "Usage: mail-alias-add <alias-address> <target-address>" >&2
	exit 2
fi

ALIAS_ADDRESS="$1"
TARGET_ADDRESS="$2"

for f in domains mailboxes aliases; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

validate_address() {
	local addr="$1" label="$2"
	if [[ "$addr" != *@* ]]; then
		echo "[ERROR] not a valid $label address: $addr" >&2
		exit 1
	fi
	local lp="${addr%@*}" dom="${addr#*@}"
	if ! [[ "$lp" =~ $LOCALPART_RE ]]; then
		echo "[ERROR] not a valid $label local part: $lp" >&2
		exit 1
	fi
	if ! [[ "$dom" =~ $DOMAIN_RE ]]; then
		echo "[ERROR] not a valid $label domain: $dom" >&2
		exit 1
	fi
}

validate_address "$ALIAS_ADDRESS" "alias"
validate_address "$TARGET_ADDRESS" "target"

if [[ "$ALIAS_ADDRESS" == "$TARGET_ADDRESS" ]]; then
	echo "[ERROR] alias address must differ from target address: $ALIAS_ADDRESS" >&2
	exit 1
fi

ALIAS_DOMAIN="${ALIAS_ADDRESS#*@}"

if ! grep -qxF "$ALIAS_DOMAIN" "$BASE/domains"; then
	echo "[ERROR] alias domain is not a configured canonical domain: $ALIAS_DOMAIN" >&2
	exit 1
fi

if grep -qxF "$ALIAS_ADDRESS" "$BASE/mailboxes"; then
	echo "[ERROR] alias address is already a mailbox: $ALIAS_ADDRESS" >&2
	exit 1
fi

if awk -v a="$ALIAS_ADDRESS" '$1==a' "$BASE/aliases" | grep -q .; then
	echo "[ERROR] alias already exists: $ALIAS_ADDRESS" >&2
	exit 1
fi

TARGET_DOMAIN="${TARGET_ADDRESS#*@}"

# Target is either an existing local mailbox, or an address outside our
# managed canonical domains (external). If the target domain is one of
# ours but the address is not a real mailbox, reject - that would be
# the start of an alias chain.
if grep -qxF "$TARGET_DOMAIN" "$BASE/domains"; then
	if ! grep -qxF "$TARGET_ADDRESS" "$BASE/mailboxes"; then
		echo "[ERROR] target is a local domain but not an existing mailbox (alias chains not supported): $TARGET_ADDRESS" >&2
		exit 1
	fi
fi

TMP=$(mktemp "$BASE/.aliases.XXXXXX")
cp -p "$BASE/aliases" "$TMP"
echo "$ALIAS_ADDRESS $TARGET_ADDRESS" >> "$TMP"
mv "$TMP" "$BASE/aliases"

echo "[OK] alias added: $ALIAS_ADDRESS -> $TARGET_ADDRESS"
echo ""
echo "-- lazy-admin-tools - dragons@work"
