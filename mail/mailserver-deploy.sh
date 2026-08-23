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
#
# When dkim_backend = rspamd in config, also installs the generated
# rspamd-dkim_signing.conf to /etc/rspamd/local.d/dkim_signing.conf
# and restarts rspamd - backed up and rolled back the same way as
# dovecot-users. Skipped entirely (no error) when DKIM is not
# enabled; this script never installs or configures rspamd itself,
# only manages this one generated file once rspamd already exists.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
STABLE="$BASE/generated"
GENERATIONS="$BASE/generations"
BACKUPS="$BASE/backups"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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

# Read early, before the first "Step N/$TOTAL_STEPS" message - with
# set -u, using TOTAL_STEPS before it is assigned is a hard failure,
# not just a cosmetic gap.
DKIM_BACKEND=$(read_config dkim_backend)

if [[ "$DKIM_BACKEND" == rspamd ]]; then
	TOTAL_STEPS=12
	RELOAD_STEP=10
	LIVE_STEP=11
	DONE_STEP=12
else
	TOTAL_STEPS=11
	RELOAD_STEP=9
	LIVE_STEP=10
	DONE_STEP=11
fi

echo "=== Step 1/$TOTAL_STEPS: mailserver-validate ==="
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

# Both generated OpenSMTPD fragments must be included - not just
# smtpd-mailhosting.conf. smtpd-mailtls.conf carries the listeners
# (25/587), submission_auth, and - when dkim_backend = rspamd - the
# rspamd_outgoing filter wiring. A host missing this include could
# otherwise complete a deploy successfully while the generated DKIM
# filter never actually becomes active.
if ! grep -q 'include[[:space:]]*"'"$STABLE"'/smtpd-mailhosting.conf"' "$SMTPD_CONF_PATH"; then
	echo "[ERROR] $SMTPD_CONF_PATH does not include $STABLE/smtpd-mailhosting.conf" >&2
	echo "[ERROR] add this line once, by hand, before running deploy:" >&2
	echo "[ERROR]   include \"$STABLE/smtpd-mailhosting.conf\"" >&2
	exit 1
fi
if ! grep -q 'include[[:space:]]*"'"$STABLE"'/smtpd-mailtls.conf"' "$SMTPD_CONF_PATH"; then
	echo "[ERROR] $SMTPD_CONF_PATH does not include $STABLE/smtpd-mailtls.conf" >&2
	echo "[ERROR] add this line once, by hand, before running deploy:" >&2
	echo "[ERROR]   include \"$STABLE/smtpd-mailtls.conf\"" >&2
	exit 1
fi

echo ""
echo "=== Step 2/$TOTAL_STEPS: pre-flight - current production state must already be healthy ==="
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

if [[ "$DKIM_BACKEND" == rspamd ]]; then
	if ! command -v rspamadm >/dev/null 2>&1; then
		echo "[ERROR] dkim_backend = rspamd but rspamadm not found - install rspamd first" >&2
		exit 1
	fi
	# filter-rspamd is not on PATH by design - OpenSMTPD's proc-exec
	# calls it by full path, it does not need to be a PATH-resolvable
	# command. dpkg-installed layout (Debian/Ubuntu):
	# /usr/libexec/opensmtpd/filter-rspamd.
	if [[ ! -x /usr/libexec/opensmtpd/filter-rspamd ]]; then
		echo "[ERROR] dkim_backend = rspamd but /usr/libexec/opensmtpd/filter-rspamd not found or not executable - install opensmtpd-filter-rspamd first" >&2
		exit 1
	fi
	if [[ ! -d /etc/rspamd ]]; then
		echo "[ERROR] dkim_backend = rspamd but /etc/rspamd does not exist" >&2
		exit 1
	fi
	if ! rspamadm configtest > /dev/null 2>&1; then
		echo "[ERROR] current production rspamd configuration is already invalid - aborting before deploy" >&2
		echo "[ERROR] fix the existing production rspamd configuration first" >&2
		exit 1
	fi
	echo "[OK] current production rspamd configuration validates"
fi

echo ""
echo "=== Step 3/$TOTAL_STEPS: build new generation ==="
GENERATION_ID="$(date -u +%Y-%m-%dT%H%M%SZ)"
NEW_GENERATION="$GENERATIONS/$GENERATION_ID"
if ! "$SCRIPT_DIR/mailserver-generate.sh" --output "$NEW_GENERATION"; then
	echo "[ERROR] generation failed - aborting deploy" >&2
	rm -rf "$NEW_GENERATION"
	exit 1
fi

echo ""
echo "=== Step 4/$TOTAL_STEPS: validate new generation (self-contained) ==="
if ! "$SCRIPT_DIR/mailserver-validate-generated.sh" --dir "$NEW_GENERATION"; then
	echo "[ERROR] new generation failed validation - aborting deploy, nothing promoted" >&2
	exit 1
fi

echo ""
echo "=== Step 5/$TOTAL_STEPS: backup dovecot-users ==="
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
	if [[ "${RSPAMD_DKIM_INSTALLED:-no}" == yes ]]; then
		if [[ -n "${RSPAMD_DKIM_BACKUP:-}" && -f "$RSPAMD_DKIM_BACKUP" ]]; then
			cp "$RSPAMD_DKIM_BACKUP" /etc/rspamd/local.d/dkim_signing.conf
			echo "[OK] rolled back /etc/rspamd/local.d/dkim_signing.conf" >&2
		else
			# No prior file existed before this run - remove what we
			# installed rather than leave a config the store no longer
			# vouches for.
			rm -f /etc/rspamd/local.d/dkim_signing.conf
			echo "[OK] removed /etc/rspamd/local.d/dkim_signing.conf (none existed before this run)" >&2
		fi
		systemctl restart rspamd 2>/dev/null || true
	fi
	systemctl restart dovecot 2>/dev/null || true
	systemctl restart opensmtpd 2>/dev/null || true
	echo "[ERROR] rollback complete" >&2
}

echo ""
echo "=== Step 6/$TOTAL_STEPS: atomic promotion (symlink swap) ==="

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
echo "=== Step 7/$TOTAL_STEPS: validate production smtpd.conf against new generation ==="
if ! smtpd -f "$SMTPD_CONF_PATH" -n; then
	echo "[ERROR] production smtpd.conf does not validate with new generation" >&2
	rollback
	exit 1
fi
echo "[OK] production smtpd.conf validates"

echo ""
echo "=== Step 8/$TOTAL_STEPS: install dovecot-users ==="
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

# --- Optional: rspamd DKIM config, only when dkim_backend = rspamd.
#     Installed and validated BEFORE any service is restarted -
#     otherwise OpenSMTPD could already be running the new generation
#     (with the new/changed rspamd_outgoing filter wiring) while
#     rspamd itself still had the OLD domain->key mapping, leaving a
#     window where submission is accepted for a domain rspamd doesn't
#     know how to sign yet. Same care as the dovecot-users install
#     above: back up the current file, install, validate again with
#     the new file in place - reverting on any failure. Skipped
#     entirely, without error, when DKIM is not enabled; the presence
#     of rspamadm/filter-rspamd/a healthy existing rspamd config was
#     already required in step 2's pre-flight. ---
RSPAMD_DKIM_INSTALLED=no
RSPAMD_DKIM_BACKUP=""

if [[ "$DKIM_BACKEND" == rspamd ]]; then
	echo ""
	echo "=== Step 9/$TOTAL_STEPS: install rspamd DKIM config ==="

	RSPAMD_DKIM_TARGET=/etc/rspamd/local.d/dkim_signing.conf

	if [[ -f "$RSPAMD_DKIM_TARGET" ]]; then
		RSPAMD_DKIM_BACKUP="$BACKUP_GENERATION/rspamd-dkim_signing.conf"
		cp -p "$RSPAMD_DKIM_TARGET" "$RSPAMD_DKIM_BACKUP"
		echo "[OK] rspamd-dkim_signing.conf backed up to $RSPAMD_DKIM_BACKUP"
	fi

	TMP_RSPAMD_DKIM=$(mktemp "$(dirname "$RSPAMD_DKIM_TARGET")/.dkim_signing.XXXXXX")
	cp "$NEW_GENERATION/rspamd-dkim_signing.conf" "$TMP_RSPAMD_DKIM"
	chmod 644 "$TMP_RSPAMD_DKIM"
	mv "$TMP_RSPAMD_DKIM" "$RSPAMD_DKIM_TARGET"
	RSPAMD_DKIM_INSTALLED=yes

	if ! rspamadm configtest >/dev/null 2>&1; then
		echo "[ERROR] production rspamd configuration does not validate with the new DKIM config" >&2
		rollback
		exit 1
	fi
	echo "[OK] installed $RSPAMD_DKIM_TARGET, production rspamd configuration validates"
fi

echo ""
echo "=== Step $RELOAD_STEP/$TOTAL_STEPS: reload services ==="
# Order matters: dovecot and rspamd (if enabled) come up first, then
# opensmtpd last - so submission on port 587 does not start accepting
# mail again until the DKIM signer it depends on is already running
# with the new domain->key mapping.
if ! systemctl restart dovecot; then
	rollback
	exit 1
fi
echo "[OK] dovecot restarted"

if [[ "$RSPAMD_DKIM_INSTALLED" == yes ]]; then
	if ! systemctl restart rspamd; then
		rollback
		exit 1
	fi
	echo "[OK] rspamd restarted"
fi

if ! systemctl restart opensmtpd; then
	rollback
	exit 1
fi
echo "[OK] opensmtpd restarted"

echo ""
echo "=== Step $LIVE_STEP/$TOTAL_STEPS: live verification ==="
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
echo "=== Step $DONE_STEP/$TOTAL_STEPS: done ==="
echo "[OK] mailserver-deploy complete"
echo "[OK] active generation: $NEW_GENERATION"
echo "[OK] previous generation retained for rollback: ${PREV_GENERATION:-none}"
echo "[OK] dovecot-users backup: $BACKUP_GENERATION"
echo ""
echo "-- lazy-admin-tools - dragons@work"
