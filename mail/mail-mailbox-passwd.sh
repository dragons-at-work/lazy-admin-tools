#!/bin/bash
# lazy-admin-tools: Reset a mailbox's password (administrative)
# Usage: mail-mailbox-passwd <address>
#        mail-mailbox-passwd --hash '<existing-hash>' <address>
#
# Administrative reset: root sets a new password without knowing the
# old one. This is deliberately separate from a self-service password
# change (planned as mail-passwd), which would require the current
# owner to authenticate with the old password first and needs its own
# privileged interface design - out of scope here.
#
# Only secrets/users is touched. The mailbox itself (mailboxes,
# aliases pointing at it) is left untouched - this tool changes a
# credential, not the mailbox's existence or routing.
#
# Stored credential format in secrets/users is a raw SHA512-Crypt hash
# ($6$...), with or without rounds=N$ - no {SCHEME} prefix. Same
# convention as mail-mailbox-add.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

HASH_RE='^\$6\$(rounds=[0-9]+\$)?[^$]+\$[^$]+$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

HASH=""
if [[ "${1:-}" == "--hash" ]]; then
	if [[ $# -lt 3 || -z "${2:-}" ]]; then
		echo "Usage: mail-mailbox-passwd [--hash '<existing-hash>'] <address>" >&2
		exit 2
	fi
	HASH="$2"
	shift 2
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: mail-mailbox-passwd [--hash '<existing-hash>'] <address>" >&2
	exit 2
fi

ADDRESS="$1"

if [[ ! -f "$BASE/secrets/users" ]]; then
	echo "[ERROR] $BASE/secrets/users not found - run mailserver-init first" >&2
	exit 1
fi

if [[ ! -f "$BASE/mailboxes" ]]; then
	echo "[ERROR] $BASE/mailboxes not found - run mailserver-init first" >&2
	exit 1
fi

if ! grep -qxF "$ADDRESS" "$BASE/mailboxes"; then
	echo "[ERROR] no such mailbox: $ADDRESS" >&2
	exit 1
fi

if ! awk -F: -v a="$ADDRESS" '$1==a' "$BASE/secrets/users" | grep -q .; then
	echo "[ERROR] mailbox exists but has no credential entry: $ADDRESS - this is an inconsistent store, fix manually" >&2
	exit 1
fi

# --- Determine password hash ---
if [[ -n "$HASH" ]]; then
	if ! [[ "$HASH" =~ $HASH_RE ]]; then
		echo "[ERROR] --hash is not a valid SHA512-Crypt hash: $HASH" >&2
		exit 1
	fi
else
	if ! command -v doveadm >/dev/null 2>&1; then
		echo "[ERROR] doveadm not found - install dovecot-core or use --hash" >&2
		exit 1
	fi
	if [[ ! -t 0 ]]; then
		echo "[ERROR] no terminal to prompt for a password - use --hash for non-interactive use" >&2
		exit 1
	fi
	read -rsp "New password: " PW1
	echo
	read -rsp "Repeat password: " PW2
	echo
	if [[ "$PW1" != "$PW2" ]]; then
		echo "[ERROR] passwords do not match" >&2
		exit 1
	fi
	if [[ -z "$PW1" ]]; then
		echo "[ERROR] password must not be empty" >&2
		exit 1
	fi
	HASH=$(doveadm pw -s SHA512-CRYPT -p "$PW1")
	HASH="${HASH#\{SHA512-CRYPT\}}"
	unset PW1 PW2
	if ! [[ "$HASH" =~ $HASH_RE ]]; then
		echo "[ERROR] generated password hash is not valid SHA512-Crypt" >&2
		exit 1
	fi
fi

# --- Atomic replace: rewrite secrets/users, replacing only the
#     matched address's hash. awk reconstructs every line via print,
#     so this relies on the simple "address:hash" format round-
#     tripping unchanged through awk's field/OFS handling - not on
#     literal byte-for-byte passthrough of unmatched lines. ---
TMP_USERS=$(mktemp "$BASE/secrets/.users.XXXXXX")
cleanup() { rm -f "$TMP_USERS"; }
trap cleanup EXIT

awk -F: -v a="$ADDRESS" -v h="$HASH" '
	BEGIN { OFS=":" }
	$1==a { print a, h; next }
	{ print }
' "$BASE/secrets/users" > "$TMP_USERS"

# Sanity check: the rewrite must still contain exactly one line for
# this address, with the new hash - never install a rewrite that
# silently dropped or duplicated the entry.
MATCH_COUNT=$(awk -F: -v a="$ADDRESS" '$1==a' "$TMP_USERS" | wc -l)
if [[ "$MATCH_COUNT" -ne 1 ]]; then
	echo "[ERROR] rewrite produced $MATCH_COUNT entries for $ADDRESS (expected 1) - aborting, not installed" >&2
	exit 1
fi
if ! awk -F: -v a="$ADDRESS" -v h="$HASH" '$1==a && $2==h { found=1 } END { exit !found }' "$TMP_USERS"; then
	echo "[ERROR] rewrite did not produce the expected new hash for $ADDRESS - aborting, not installed" >&2
	exit 1
fi

chmod --reference="$BASE/secrets/users" "$TMP_USERS" 2>/dev/null || chmod 600 "$TMP_USERS"
mv "$TMP_USERS" "$BASE/secrets/users"

echo "[OK] password reset: $ADDRESS"
echo ""
echo "-- lazy-admin-tools - dragons@work"
