#!/bin/bash
# lazy-admin-tools: cert-renew-install - schedule cert-renew for the host
# Usage: cert-renew-install
#
# Installs a daily periodic run of cert-renew, using whichever
# scheduling mechanism fits the host, so nobody has to remember how
# this was set up on a given server months later:
#
#   systemd hosts (Debian and similar) -> /etc/cron.d/<name>
#   rcctl hosts (OpenBSD)              -> root's crontab
#
# Idempotent: running this again does not create duplicate entries.
# Runs daily at a fixed but non-round time (04:17) to avoid piling
# onto every other job's :00 slot; cert-renew itself is cheap to run
# when nothing is due, so daily is deliberately generous rather than
# trying to time it to any renewal window.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CERT_RENEW="$SCRIPT_DIR/cert-renew.sh"

# --- Configuration ---
LOG_FILE=/var/log/cert-renew.log
CRON_MINUTE=17
CRON_HOUR=4
CRON_D_FILE=/etc/cron.d/lazy-admin-tools-cert-renew
MARKER="# lazy-admin-tools: cert-renew"
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

if [[ ! -x "$CERT_RENEW" ]]; then
	echo "[ERROR] cert-renew not found or not executable: $CERT_RENEW" >&2
	exit 1
fi

touch "$LOG_FILE"
chown root:root "$LOG_FILE"
chmod 0640 "$LOG_FILE"
echo "[OK] log file ready: $LOG_FILE (root:root 0640)"

CRON_LINE="$CRON_MINUTE $CRON_HOUR * * * root $CERT_RENEW >> $LOG_FILE 2>&1"

if command -v rcctl >/dev/null 2>&1; then
	# --- OpenBSD: root's crontab, no cron.d convention ---
	EXISTING="$(crontab -l -u root 2>/dev/null || true)"
	if echo "$EXISTING" | grep -qF "$CERT_RENEW"; then
		echo "[OK] already scheduled in root's crontab"
		exit 0
	fi

	TMP_CRONTAB=$(mktemp)
	trap 'rm -f "$TMP_CRONTAB"' EXIT
	{
		[[ -n "$EXISTING" ]] && echo "$EXISTING"
		echo "$MARKER"
		echo "$CRON_MINUTE $CRON_HOUR * * * $CERT_RENEW >> $LOG_FILE 2>&1"
	} > "$TMP_CRONTAB"
	crontab -u root "$TMP_CRONTAB"
	echo "[OK] scheduled in root's crontab: daily at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE")"

elif command -v systemctl >/dev/null 2>&1 && [[ -d /etc/cron.d ]]; then
	# --- systemd/Debian-style hosts: /etc/cron.d ---
	# /etc/cron.d existing does not prove anything reads it - on a
	# minimal install, no cron daemon may be present or running at
	# all, and an entry would silently never fire. Require cron
	# explicitly rather than assume it.
	if ! command -v cron >/dev/null 2>&1; then
		echo "[ERROR] /etc/cron.d exists but no cron daemon is installed (apt install cron)" >&2
		exit 1
	fi
	if ! systemctl is-active --quiet cron; then
		echo "[ERROR] cron is installed but not active (systemctl status cron)" >&2
		exit 1
	fi

	NEW_CONTENT="$MARKER
$CRON_LINE
"
	if [[ -f "$CRON_D_FILE" ]] && cmp -s <(echo "$NEW_CONTENT") "$CRON_D_FILE"; then
		echo "[OK] already scheduled: $CRON_D_FILE"
		exit 0
	fi

	TMP_FILE=$(mktemp "$(dirname "$CRON_D_FILE")/.cert-renew.XXXXXX")
	echo "$NEW_CONTENT" > "$TMP_FILE"
	chown root:root "$TMP_FILE"
	chmod 0644 "$TMP_FILE"
	mv "$TMP_FILE" "$CRON_D_FILE"
	echo "[OK] scheduled: $CRON_D_FILE (daily at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE"))"

else
	echo "[ERROR] no supported scheduling mechanism found (checked: rcctl/crontab, systemctl+/etc/cron.d)" >&2
	echo "[ERROR] schedule manually: $CRON_LINE" >&2
	exit 1
fi

echo ""
echo "-- lazy-admin-tools - dragons@work"
