#!/bin/bash
# lazy-admin-tools: Remove a mailbox (address + credential)
# Usage: mail-mailbox-del [--force] <address>
#
# Refuses to remove a mailbox that is still the target of an alias
# (mail-alias-add refuses to point a local alias at a non-existent
# mailbox, so removing the mailbox first would silently break that
# invariant from the other direction). Use --force to remove anyway
# and leave the affected aliases dangling - mailserver-validate will
# then report them.

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

FORCE=no
if [[ "${1:-}" == "--force" ]]; then
	FORCE=yes
	shift
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: mail-mailbox-del [--force] <address>" >&2
	exit 2
fi

ADDRESS="$1"

for f in mailboxes secrets/users aliases; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

if ! grep -qxF "$ADDRESS" "$BASE/mailboxes"; then
	echo "[ERROR] mailbox does not exist: $ADDRESS" >&2
	exit 1
fi

DEPENDENT_ALIASES=$(awk -v a="$ADDRESS" '$2==a {print $1}' "$BASE/aliases")
if [[ -n "$DEPENDENT_ALIASES" && "$FORCE" != "yes" ]]; then
	echo "[ERROR] mailbox is still the target of these aliases:" >&2
	while read -r a; do echo "[ERROR]   $a -> $ADDRESS" >&2; done <<< "$DEPENDENT_ALIASES"
	echo "[ERROR] remove those aliases first, or re-run with --force" >&2
	exit 1
fi
if [[ -n "$DEPENDENT_ALIASES" ]]; then
	echo "[WARN] removing mailbox with dependent aliases still pointing at it (--force):"
	while read -r a; do echo "[WARN]   $a -> $ADDRESS"; done <<< "$DEPENDENT_ALIASES"
fi

# --- Transactional write: prepare both temp files first, install both,
#     roll back mailboxes if the second install fails. ---
ORIG_MODE_MB=$(stat -c '%a' "$BASE/mailboxes")
ORIG_OWNER_MB=$(stat -c '%U:%G' "$BASE/mailboxes")
ORIG_MODE_USERS=$(stat -c '%a' "$BASE/secrets/users")
ORIG_OWNER_USERS=$(stat -c '%U:%G' "$BASE/secrets/users")

TMP_MAILBOXES=$(mktemp "$BASE/.mailboxes.XXXXXX")
TMP_USERS=$(mktemp "$BASE/secrets/.users.XXXXXX")
BACKUP_MAILBOXES=""

cleanup() {
	rm -f "$TMP_MAILBOXES" "$TMP_USERS"
	[[ -z "$BACKUP_MAILBOXES" ]] || rm -f "$BACKUP_MAILBOXES"
}
trap cleanup EXIT

grep -vxF "$ADDRESS" "$BASE/mailboxes" > "$TMP_MAILBOXES" || true
chmod "$ORIG_MODE_MB" "$TMP_MAILBOXES"
chown "$ORIG_OWNER_MB" "$TMP_MAILBOXES"

awk -F: -v a="$ADDRESS" '$1!=a' "$BASE/secrets/users" > "$TMP_USERS"
chmod "$ORIG_MODE_USERS" "$TMP_USERS"
chown "$ORIG_OWNER_USERS" "$TMP_USERS"

BACKUP_MAILBOXES=$(mktemp "$BASE/.mailboxes.orig.XXXXXX")
cp -p "$BASE/mailboxes" "$BACKUP_MAILBOXES"

mv "$TMP_MAILBOXES" "$BASE/mailboxes"

if ! mv "$TMP_USERS" "$BASE/secrets/users"; then
	echo "[ERROR] failed to write secrets/users, rolling back mailboxes" >&2
	mv "$BACKUP_MAILBOXES" "$BASE/mailboxes"
	exit 1
fi

echo "[OK] mailbox removed: $ADDRESS"
echo ""
echo "-- lazy-admin-tools - dragons@work"
