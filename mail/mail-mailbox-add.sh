#!/bin/bash
# lazy-admin-tools: Add a mailbox (address + credential)
# Usage: mail-mailbox-add <address>
#        mail-mailbox-add --hash '<existing-hash>' <address>
#
# Stored credential format in secrets/users is a raw SHA512-Crypt hash
# ($6$...), with or without rounds=N$ - no {SCHEME} prefix. This is the
# canonical representation whether the mailbox was created fresh or
# migrated from an existing system.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
LOCALPART_RE='^[a-zA-Z0-9._%+-]+$'
HASH_RE='^\$6\$(rounds=[0-9]+\$)?[^$]+\$[^$]+$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

HASH=""
if [[ "${1:-}" == "--hash" ]]; then
	HASH="${2:-}"
	shift 2
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: mail-mailbox-add [--hash '<existing-hash>'] <address>" >&2
	exit 2
fi

ADDRESS="$1"

for f in domains mailboxes secrets/users; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

if [[ "$ADDRESS" != *@* ]]; then
	echo "[ERROR] not a valid address: $ADDRESS" >&2
	exit 1
fi

LOCALPART="${ADDRESS%@*}"
DOMAIN="${ADDRESS#*@}"

if ! [[ "$LOCALPART" =~ $LOCALPART_RE ]]; then
	echo "[ERROR] not a valid local part: $LOCALPART" >&2
	exit 1
fi

if ! [[ "$DOMAIN" =~ $DOMAIN_RE ]]; then
	echo "[ERROR] not a valid domain: $DOMAIN" >&2
	exit 1
fi

if ! grep -qxF "$DOMAIN" "$BASE/domains"; then
	echo "[ERROR] domain is not a configured canonical domain: $DOMAIN" >&2
	exit 1
fi

if grep -qxF "$ADDRESS" "$BASE/mailboxes"; then
	echo "[ERROR] mailbox already exists: $ADDRESS" >&2
	exit 1
fi

if awk -F: -v a="$ADDRESS" '$1==a' "$BASE/secrets/users" | grep -q .; then
	echo "[ERROR] credential already exists for: $ADDRESS" >&2
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
	read -rsp "Password: " PW1
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

# --- Transactional write: prepare both temp files first, install both,
#     roll back mailboxes if the second install fails. ---
TMP_MAILBOXES=$(mktemp "$BASE/.mailboxes.XXXXXX")
TMP_USERS=$(mktemp "$BASE/secrets/.users.XXXXXX")
BACKUP_MAILBOXES=""

cleanup() {
	rm -f "$TMP_MAILBOXES" "$TMP_USERS"
	[[ -z "$BACKUP_MAILBOXES" ]] || rm -f "$BACKUP_MAILBOXES"
}
trap cleanup EXIT

cp -p "$BASE/mailboxes" "$TMP_MAILBOXES"
echo "$ADDRESS" >> "$TMP_MAILBOXES"

cp -p "$BASE/secrets/users" "$TMP_USERS"
echo "${ADDRESS}:${HASH}" >> "$TMP_USERS"

BACKUP_MAILBOXES=$(mktemp "$BASE/.mailboxes.orig.XXXXXX")
cp -p "$BASE/mailboxes" "$BACKUP_MAILBOXES"

mv "$TMP_MAILBOXES" "$BASE/mailboxes"

if ! mv "$TMP_USERS" "$BASE/secrets/users"; then
	echo "[ERROR] failed to write secrets/users, rolling back mailboxes" >&2
	mv "$BACKUP_MAILBOXES" "$BASE/mailboxes"
	exit 1
fi

echo "[OK] mailbox added: $ADDRESS"
echo ""
echo "-- lazy-admin-tools - dragons@work"
