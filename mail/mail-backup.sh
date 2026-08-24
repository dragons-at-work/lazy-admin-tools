#!/bin/bash
# lazy-admin-tools: mail-backup - back up the mailserver store, generated
# config, and maildir data (one archive per domain).
# Usage: mail-backup.sh [--dest-host <host>] [--dest-path <path>] [--retention-days N]
#
# Local backups always go to $BACKUP_ROOT. If --dest-host is given, the
# run's backup directory is additionally rsync'd there over ssh - this
# script does not manage credentials or ssh keys itself, that setup is
# a one-time manual step (see docs/operations.md).
#
# Per-domain maildir archives are separate tar files rather than one
# combined archive, so a single domain's data can be restored (or
# inspected) without extracting everything else.
#
# Each run gets its own timestamped directory (not just a date) - a
# second run on the same day never overwrites a prior run's archives,
# and a run that fails partway through never looks like a mix of two
# different points in time.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] must run as root - this backs up secrets/users, dovecot-users, and other users' maildirs" >&2
	exit 1
fi

BASE=/etc/mailserver
BACKUP_ROOT=/var/backups/mailserver
RETENTION_DAYS=14
DEST_HOST=""
DEST_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dest-host)
			[[ $# -ge 2 ]] || { echo "[ERROR] --dest-host requires a value" >&2; exit 2; }
			DEST_HOST="$2"; shift 2 ;;
		--dest-path)
			[[ $# -ge 2 ]] || { echo "[ERROR] --dest-path requires a value" >&2; exit 2; }
			DEST_PATH="$2"; shift 2 ;;
		--retention-days)
			[[ $# -ge 2 ]] || { echo "[ERROR] --retention-days requires a value" >&2; exit 2; }
			RETENTION_DAYS="$2"; shift 2 ;;
		*)
			echo "Usage: mail-backup.sh [--dest-host <host>] [--dest-path <path>] [--retention-days N]" >&2
			exit 2
			;;
	esac
done

if [[ ! -d "$BASE" ]]; then
	echo "[ERROR] $BASE not found - is mailserver-init run on this host?" >&2
	exit 1
fi

VMAIL_BASE="$(grep '^vmail_base' "$BASE/config" 2>/dev/null || true)"
VMAIL_BASE="$(awk -F' = ' '{print $2}' <<< "$VMAIL_BASE")"
VMAIL_BASE="${VMAIL_BASE:-/var/vmail}"
DOVECOT_USERS_PATH="$(grep '^dovecot_users_path' "$BASE/config" 2>/dev/null || true)"
DOVECOT_USERS_PATH="$(awk -F' = ' '{print $2}' <<< "$DOVECOT_USERS_PATH")"
DOVECOT_USERS_PATH="${DOVECOT_USERS_PATH:-/etc/dovecot/users}"

RUN_ID="$(date +%Y%m%dT%H%M%S)"
RUN_DIR="$BACKUP_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
chmod 700 "$BACKUP_ROOT" "$RUN_DIR"

FAILED=no

echo "=== mail-backup $RUN_ID ==="

# --- 1. Declarative store only: the authoritative files an admin
#     actually edits, not generated/generations/backups (those are
#     deployment artifacts and deployment-created backups, not source
#     of truth - archiving them here would blur the store/generation
#     split the rest of the toolchain keeps deliberately separate).
#     dovecot_users_path lives outside $BASE and is included
#     explicitly for the same reason mailserver-deploy backs it up
#     separately from the generated/ symlink target. ---
STORE_FILES=(domains domain-aliases config domain-overrides mailboxes aliases defaults secrets)
STORE_TAR="$RUN_DIR/store-$RUN_ID.tar.gz"
STORE_TAR_ARGS=()
STORE_MISSING=no
for f in "${STORE_FILES[@]}"; do
	if [[ -e "$BASE/$f" ]]; then
		STORE_TAR_ARGS+=("$f")
	else
		echo "[ERROR] store file missing: $BASE/$f" >&2
		STORE_MISSING=yes
		FAILED=yes
	fi
done
if [[ "$STORE_MISSING" == yes ]]; then
	echo "[ERROR] store backup skipped - one or more required files are missing (see above)" >&2
elif tar -czf "$STORE_TAR" -C "$BASE" "${STORE_TAR_ARGS[@]}" \
		-C / "${DOVECOT_USERS_PATH#/}" 2>&1; then
	chmod 600 "$STORE_TAR"
	echo "[OK] store backed up: $STORE_TAR"
else
	echo "[ERROR] store backup failed" >&2
	FAILED=yes
fi

# --- 2. Currently active generation (symlink target), for a complete
#     picture of what was actually deployed, not just the declarative
#     source. The store backup above can regenerate this, but having
#     the actual deployed artifacts too avoids depending on generation
#     working correctly during a restore. ---
if [[ -L "$BASE/generated" ]]; then
	GEN_TARGET="$(readlink -f "$BASE/generated")"
	if [[ -d "$GEN_TARGET" ]]; then
		GEN_TAR="$RUN_DIR/active-generation-$RUN_ID.tar.gz"
		if tar -czf "$GEN_TAR" -C "$(dirname "$GEN_TARGET")" "$(basename "$GEN_TARGET")" 2>&1; then
			chmod 600 "$GEN_TAR"
			echo "[OK] active generation backed up: $GEN_TAR"
		else
			echo "[ERROR] active generation backup failed" >&2
			FAILED=yes
		fi
	fi
else
	echo "[WARN] no active generation symlink at $BASE/generated - skipped"
fi

# --- 3. One maildir archive per domain, not one combined archive -
#     restoring or inspecting a single domain's mail should not
#     require extracting every other domain's data too. ---
MAILDIR_DIR="$RUN_DIR/maildir"
mkdir -p "$MAILDIR_DIR"
DOMAIN_COUNT=0
while IFS= read -r domain; do
	[[ -z "$domain" ]] && continue
	domain_path="$VMAIL_BASE/$domain"
	if [[ ! -d "$domain_path" ]]; then
		echo "[WARN] $domain: no maildir at $domain_path - skipped"
		continue
	fi
	domain_tar="$MAILDIR_DIR/$domain.tar.gz"
	if tar -czf "$domain_tar" -C "$VMAIL_BASE" "$domain" 2>&1; then
		chmod 600 "$domain_tar"
		size="$(du -h "$domain_tar" | cut -f1)"
		echo "[OK] $domain: maildir backed up ($size)"
		DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
	else
		echo "[ERROR] $domain: maildir backup failed" >&2
		FAILED=yes
	fi
done < <(grep -v '^[[:space:]]*#' "$BASE/domains" | grep -v '^[[:space:]]*$')

echo "[OK] $DOMAIN_COUNT domain(s) backed up to $MAILDIR_DIR"

# --- 4. Optional off-host copy. Local backup above always happens
#     regardless of whether this succeeds - a failed remote copy must
#     not be mistaken for "no backup exists at all". ---
if [[ -n "$DEST_HOST" ]]; then
	remote_path="${DEST_PATH:-/var/backups/mailserver-remote}/$(hostname -s)"
	if rsync -a "$RUN_DIR" "$DEST_HOST:$remote_path/" 2>&1; then
		echo "[OK] copied to $DEST_HOST:$remote_path/$RUN_ID"
	else
		echo "[ERROR] rsync to $DEST_HOST failed - local backup at $RUN_DIR is still intact" >&2
		FAILED=yes
	fi
fi

# --- 5. Retention: local copies only. Remote retention (if any) is
#     the receiving host's own responsibility. ---
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION_DAYS" -print0 2>/dev/null \
	| xargs -0 -r rm -rf
echo "[OK] retention applied ($RETENTION_DAYS days)"

if [[ "$FAILED" == yes ]]; then
	echo "[WARN] mail-backup completed with errors - see above"
	echo "-- lazy-admin-tools - dragons@work"
	exit 1
fi

echo "[OK] mail-backup complete: $RUN_DIR"
echo "-- lazy-admin-tools - dragons@work"
