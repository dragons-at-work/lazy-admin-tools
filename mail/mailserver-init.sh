#!/bin/bash
# lazy-admin-tools: Mailserver data store initialization
# Creates /etc/mailserver skeleton with defaults. Idempotent - safe to
# run multiple times, never overwrites existing files.
#
# /etc/mailserver/secrets/users is the source of truth for mailbox
# credentials. /etc/dovecot/users (once generated) is a derived
# artifact and must not be edited directly.

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

create_dir() {
	local path="$1" mode="$2"
	if [[ -d "$path" ]]; then
		echo "[OK] existing directory preserved: $path"
	else
		mkdir -p "$path"
		echo "[OK] created directory: $path"
	fi
	chown root:root "$path"
	chmod "$mode" "$path"
}

create_file() {
	local path="$1" mode="$2"
	shift 2
	if [[ -f "$path" ]]; then
		echo "[OK] existing file preserved: $path"
	else
		printf '%s\n' "$@" > "$path"
		echo "[OK] created file: $path"
	fi
	chown root:root "$path"
	chmod "$mode" "$path"
}

create_dir "$BASE" 0755
create_dir "$BASE/secrets" 0700

create_file "$BASE/domains" 0644 \
	"# One canonical mail domain per line."

create_file "$BASE/domain-aliases" 0644 \
	"# Alias domains without own mailboxes." \
	"# Format: <alias-domain> <canonical-domain>"

create_file "$BASE/config" 0644 \
	"# Global mail platform defaults. Override per-domain in domain-overrides." \
	"imap_hostname_pattern = imap.%domain%" \
	"smtp_hostname_pattern = smtp.%domain%" \
	"mx_hostname_pattern = mail.%domain%" \
	"dkim_selector = mail" \
	"vmail_base = /var/vmail" \
	"smtpd_conf_path = /etc/smtpd.conf" \
	"dovecot_users_path = /etc/dovecot/users" \
	"dovecot_lmtp_socket = /run/dovecot/lmtp"

create_file "$BASE/domain-overrides" 0644 \
	"# Per-domain overrides for config." \
	"# Format: <domain> <key> <value>"

create_file "$BASE/mailboxes" 0644 \
	"# One mailbox address per line."

create_file "$BASE/aliases" 0644 \
	"# Format: <alias-address> <target-address>"

create_file "$BASE/defaults" 0644 \
	"# Administrative role local-parts, one per line." \
	"postmaster" \
	"abuse" \
	"webmaster" \
	"hostmaster"

create_file "$BASE/secrets/users" 0600 \
	"# Source of truth for mailbox credentials." \
	"# Format: <address>:<password-hash>"

echo "[OK] mailserver-init complete"
echo ""
echo "-- lazy-admin-tools - dragons@work"
