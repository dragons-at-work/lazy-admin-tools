#!/bin/bash
# lazy-admin-tools: Deploy generated mailserver artifacts
# Usage: mailserver-deploy
#
# Generation-based, symlink-promoted deploy:
#
#   /etc/mailserver/generations/<timestamp>/   <- fresh, self-contained
#                                                  generation, built and
#                                                  fully validated BEFORE
#                                                  anything production
#                                                  is touched
#   /etc/mailserver/generated -> generations/<timestamp>/
#                                              <- single atomic symlink
#                                                 swap activates (or, on
#                                                 failure, reverts) an
#                                                 entire generation at
#                                                 once
#
# This guarantees smtpd-mailhosting.conf and the five OpenSMTPD tables
# it references always come from the SAME generation - an aborted
# deploy cannot leave a mix of old and new tables in place, which a
# plain "overwrite files in generated/ one by one" approach could.
#
# The previous generation directory is left on disk untouched and
# doubles as the rollback target - no separate backup copy of the
# OpenSMTPD artifacts is needed. dovecot-users (containing password
# hashes, installed outside of generated/) is still backed up
# separately before being overwritten.
#
# This script NEVER edits /etc/smtpd.conf. The host's own smtpd.conf
# must already contain:
#   include "/etc/mailserver/generated/smtpd-mailhosting.conf"
# alongside its own <aliases>, <localdomains> tables and outbound
# relay action. mailserver-generate documents this requirement.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
STABLE="$BASE/generated"
GENERATIONS="$BASE/generations"
BACKUPS="$BASE/backups"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

read_config() {
	local key="$1"
	awk -F'=' -v k="$key" '
		{
			trimmed_key = $1
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed_key)
		}
		trimmed_key == k {
			val = $0
			sub(/^[^=]*=/, "", val)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			print val
			exit
		}
	' "$BASE/config"
}

mkdir -p "$GENERATIONS"
chmod 700 "$GENERATIONS"

echo "=== Step 1/11: mailserver-validate ==="
if ! "$SCRIPT_DIR/mailserver-validate.sh"; then
	echo "[ERROR] store validation failed - aborting deploy" >&2
	exit 1
fi

DOVECOT_USERS_PATH=$(read_config dovecot_users_path)
if [[ -z "$DOVECOT_USERS_PATH" ]]; then
	echo "[ERROR] dovecot_users_path not set in $BASE/config" >&2
	exit 1
fi

SMTPD_CONF_PATH=$(read_config smtpd_conf_path)
if [[ -z "$SMTPD_CONF_PATH" ]]; then
	echo "[ERROR] smtpd_conf_path not set in $BASE/config" >&2
	exit 1
fi

if [[ ! -f "$SMTPD_CONF_PATH" ]]; then
	echo "[ERROR] $SMTPD_CONF_PATH does not exist" >&2
	exit 1
fi

if ! grep -q 'include[[:space:]]*"'"$STABLE"'/smtpd-mailhosting.conf"' "$SMTPD_CONF_PATH"; then
	echo "[ERROR] $SMTPD_CONF_PATH does not include $STABLE/smtpd-mailhosting.conf" >&2
	echo "[ERROR] add this line once, by hand, before running deploy:" >&2
	echo "[ERROR]   include \"$STABLE/smtpd-mailhosting.conf\"" >&2
	exit 1
fi

echo ""
echo "=== Step 2/11: pre-flight - current production state must already be healthy ==="
# A deploy is not responsible for fixing a host that was already
# broken before it ran - it should refuse to build on top of that,
# not attempt a promotion and rely on rollback to notice later.
if ! smtpd -f "$SMTPD_CONF_PATH" -n > /dev/null 2>&1; then
	echo "[ERROR] current production smtpd.conf is already invalid - aborting before deploy" >&2
	echo "[ERROR] fix the existing production OpenSMTPD configuration first" >&2
	exit 1
fi
echo "[OK] current production smtpd.conf validates"

if ! doveconf -n > /dev/null 2>&1; then
	echo "[ERROR] current production Dovecot configuration is already invalid - aborting before deploy" >&2
	echo "[ERROR] fix the existing production Dovecot configuration first" >&2
	exit 1
fi
echo "[OK] current production Dovecot configuration validates"

echo ""
echo "=== Step 3/11: build new generation ==="
GENERATION_ID="$(date -u +%Y-%m-%dT%H%M%SZ)"
NEW_GENERATION="$GENERATIONS/$GENERATION_ID"
if ! "$SCRIPT_DIR/mailserver-generate.sh" --output "$NEW_GENERATION"; then
	echo "[ERROR] generation failed - aborting deploy" >&2
	rm -rf "$NEW_GENERATION"
	exit 1
fi

echo ""
echo "=== Step 4/11: validate new generation (self-contained) ==="
if ! "$SCRIPT_DIR/mailserver-validate-generated.sh" --dir "$NEW_GENERATION"; then
	echo "[ERROR] new generation failed validation - aborting deploy, nothing promoted" >&2
	exit 1
fi

echo ""
echo "=== Step 5/11: backup dovecot-users ==="
BACKUP_GENERATION="$BACKUPS/$GENERATION_ID"
mkdir -p "$BACKUPS"
chmod 700 "$BACKUPS"
mkdir -p "$BACKUP_GENERATION"
chmod 700 "$BACKUP_GENERATION"
if [[ -f "$DOVECOT_USERS_PATH" ]]; then
	cp -p "$DOVECOT_USERS_PATH" "$BACKUP_GENERATION/dovecot-users"
	chmod 600 "$BACKUP_GENERATION/dovecot-users"
else
	echo "[INFO] no existing $DOVECOT_USERS_PATH - nothing to back up"
fi
echo "[OK] dovecot-users backed up to $BACKUP_GENERATION"

rollback() {
	echo "" >&2
	echo "[ERROR] deploy failed - rolling back" >&2
	if [[ -n "$PREV_GENERATION" ]]; then
		TMP_LINK=$(mktemp -u "$BASE/.generated.XXXXXX")
		ln -s "$PREV_GENERATION" "$TMP_LINK"
		mv -T "$TMP_LINK" "$STABLE"
		echo "[OK] symlink reverted to previous generation: $PREV_GENERATION" >&2
	else
		echo "[WARN] no previous generation recorded - leaving symlink as-is" >&2
	fi
	if [[ -f "$BACKUP_GENERATION/dovecot-users" ]]; then
		cp "$BACKUP_GENERATION/dovecot-users" "$DOVECOT_USERS_PATH"
		# Same permissions as the normal install path (step 7) - the
		# backup copy itself is kept root:root 0600 for at-rest
		# safety, so cp -p here would silently reintroduce the
		# "dovecot auth process can't read its own passwd-file" bug.
		if getent group dovecot > /dev/null 2>&1; then
			chown root:dovecot "$DOVECOT_USERS_PATH"
			chmod 640 "$DOVECOT_USERS_PATH"
		fi
		echo "[OK] rolled back $DOVECOT_USERS_PATH (root:dovecot 0640)" >&2
	fi
	systemctl restart dovecot 2>/dev/null || true
	systemctl restart opensmtpd 2>/dev/null || true
	echo "[ERROR] rollback complete" >&2
}

echo ""
echo "=== Step 6/11: atomic promotion (symlink swap) ==="

# One-time migration: earlier versions of this tool wrote directly
# into generated/ as a plain directory. Move that aside as a
# generation and immediately re-point the stable path at it via
# symlink, so /etc/mailserver/generated is never briefly missing -
# done here (after the new generation already built + validated
# successfully), not at script start, so a failed validate/generate
# cannot leave production without a working "generated" path.
PREV_GENERATION=""
if [[ -d "$STABLE" && ! -L "$STABLE" ]]; then
	LEGACY="$GENERATIONS/pre-generations-$GENERATION_ID"
	mv "$STABLE" "$LEGACY"
	ln -s "$LEGACY" "$STABLE"
	echo "[INFO] migrated legacy generated/ directory to $LEGACY"
	PREV_GENERATION="$LEGACY"
elif [[ -L "$STABLE" ]]; then
	PREV_GENERATION=$(readlink -f "$STABLE")
fi

TMP_LINK=$(mktemp -u "$BASE/.generated.XXXXXX")
ln -s "$NEW_GENERATION" "$TMP_LINK"
mv -T "$TMP_LINK" "$STABLE"
echo "[OK] generated -> $NEW_GENERATION"

echo ""
echo "=== Step 7/11: validate production smtpd.conf against new generation ==="
if ! smtpd -f "$SMTPD_CONF_PATH" -n; then
	echo "[ERROR] production smtpd.conf does not validate with new generation" >&2
	rollback
	exit 1
fi
echo "[OK] production smtpd.conf validates"

echo ""
echo "=== Step 8/11: install dovecot-users ==="
TMP_DOVECOT_USERS=$(mktemp "$(dirname "$DOVECOT_USERS_PATH")/.dovecot-users.XXXXXX")
cp "$NEW_GENERATION/dovecot-users" "$TMP_DOVECOT_USERS"
# The dovecot auth process reads this file at lookup time (unlike TLS
# keys, read once at startup before privileges are dropped), so it
# needs real read access. Per Dovecot's own passwd-file docs:
#   chmod 640 /path/to/file ; chown root:dovecot /path/to/file
if ! getent group dovecot > /dev/null 2>&1; then
	echo "[ERROR] group 'dovecot' does not exist - cannot set safe readable permissions" >&2
	rm -f "$TMP_DOVECOT_USERS"
	rollback
	exit 1
fi
chown root:dovecot "$TMP_DOVECOT_USERS"
chmod 640 "$TMP_DOVECOT_USERS"

TMP_DOVECOT_CONF=$(mktemp /tmp/mailserver-deploy-dovecot.XXXXXX.conf)
cat > "$TMP_DOVECOT_CONF" << EOF
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0
mail_driver = maildir
mail_home = /var/vmail/%{user | domain}/%{user | username}
mail_path = %{home}
mail_uid = vmail
mail_gid = vmail
auth_username_format = %{user | lower}
passdb passwd-file {
  default_password_scheme = SHA512-CRYPT
  passwd_file_path = $TMP_DOVECOT_USERS
}
userdb static {
  fields {
    uid = vmail
    gid = vmail
  }
}
EOF
if ! doveconf -c "$TMP_DOVECOT_CONF" -n > /dev/null; then
	echo "[ERROR] staged dovecot-users does not validate" >&2
	rm -f "$TMP_DOVECOT_USERS" "$TMP_DOVECOT_CONF"
	rollback
	exit 1
fi
rm -f "$TMP_DOVECOT_CONF"

mv "$TMP_DOVECOT_USERS" "$DOVECOT_USERS_PATH"
echo "[OK] installed $DOVECOT_USERS_PATH (root:dovecot 0640)"

echo ""
echo "=== Step 9/11: reload services ==="
if ! systemctl restart dovecot; then
	rollback
	exit 1
fi
echo "[OK] dovecot restarted"

if ! systemctl restart opensmtpd; then
	rollback
	exit 1
fi
echo "[OK] opensmtpd restarted"

echo ""
echo "=== Step 10/11: live verification ==="
FIRST_USER=$(awk -F: '{print $1; exit}' "$NEW_GENERATION/dovecot-users")
if [[ -n "$FIRST_USER" ]]; then
	if doveadm user "$FIRST_USER" > /dev/null 2>&1; then
		echo "[OK] sample user resolves against live dovecot: $FIRST_USER"
	else
		echo "[ERROR] sample user does not resolve against live dovecot: $FIRST_USER" >&2
		rollback
		exit 1
	fi
else
	echo "[WARN] no users in new generation to sample-check"
fi

echo ""
echo "=== Step 11/11: done ==="
echo "[OK] mailserver-deploy complete"
echo "[OK] active generation: $NEW_GENERATION"
echo "[OK] previous generation retained for rollback: ${PREV_GENERATION:-none}"
echo "[OK] dovecot-users backup: $BACKUP_GENERATION"
echo ""
echo "-- lazy-admin-tools - dragons@work"
