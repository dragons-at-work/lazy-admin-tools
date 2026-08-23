#!/bin/bash
# lazy-admin-tools: Debian Health Check
# Runs daily via cron, sends report via mail.
#
# Host-specific baseline (which mail address, which services and
# ports are actually expected to run) lives in a separate, host-local
# config file - never in this script and never inside this repository.
# install.sh rebuilds this script's own directory from scratch on
# every run; a baseline edited directly in this file would be silently
# destroyed the next time install.sh runs. The config file below is
# never created, modified, or deleted by install.sh or by this repo -
# only by you, once, per host.

# --- Host-local configuration ---
CONF_FILE=/usr/local/etc/lazy-admin-tools/health.conf

if [[ ! -f "$CONF_FILE" ]]; then
	echo "[ERROR] $CONF_FILE not found." >&2
	echo "[ERROR] Create it with your host's real baseline, e.g.:" >&2
	echo "  sudo mkdir -p $(dirname "$CONF_FILE")" >&2
	echo "  sudo tee $CONF_FILE <<'EOF'" >&2
	echo "MAILTO=\"adm-\$(hostname -s)@example.org\"" >&2
	echo "EXPECTED_SERVICES=\"ssh ufw fail2ban\"" >&2
	echo "EXPECTED_PORTS=\"22\"" >&2
	echo "EOF" >&2
	echo "[ERROR] determine the real values first with:" >&2
	echo "  systemctl list-units --type=service --state=running --no-legend" >&2
	echo "  ss -tln" >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

for var in MAILTO EXPECTED_SERVICES EXPECTED_PORTS; do
	if [[ -z "${!var:-}" ]]; then
		echo "[ERROR] $CONF_FILE does not set $var" >&2
		exit 1
	fi
done

# --- Configuration ---
CHECK_DISK=yes
DISK_WARN_PCT=80
DISK_ERROR_PCT=95

CHECK_SERVICES=yes
CHECK_PORTS=yes
CHECK_UPDATES=yes

# --- End configuration ---

# cron uses a minimal PATH (e.g. /usr/bin:/bin) that does not include
# /usr/sbin, where tools like ufw live - set an explicit PATH so the
# script behaves the same under cron as it does interactively.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

if [[ "$(id -u)" -ne 0 ]]; then
	echo "=== Health Report $DATE ===

[ERROR] script must run as root (ufw/ss need root privileges)" | mail -s "[ERROR] $HOSTNAME health report" "$MAILTO"
	exit 1
fi

LEVEL_OK=0
LEVEL_WARN=1
LEVEL_ERROR=2
STATUS=$LEVEL_OK

DISK_LINES=""
SERVICE_LINES=""
PORT_LINES=""
UPDATE_LINES=""

# --- Disk ---
if [[ "$CHECK_DISK" == "yes" ]]; then
	DISK_LINES=$(df -h | grep -v tmpfs | awk -v warn="$DISK_WARN_PCT" -v err="$DISK_ERROR_PCT" '
		NR>1 {
			pct=$5; gsub(/%/,"",pct)
			if (pct+0 >= err)      print "[ERROR] " $6 " " $5 " full"
			else if (pct+0 >= warn) print "[WARN] " $6 " " $5 " full"
		}')
	if grep -q "\[ERROR\]" <<< "$DISK_LINES"; then STATUS=$LEVEL_ERROR
	elif grep -q "\[WARN\]" <<< "$DISK_LINES" && [[ "$STATUS" -lt "$LEVEL_WARN" ]]; then STATUS=$LEVEL_WARN
	fi
fi

# --- Services ---
if [[ "$CHECK_SERVICES" == "yes" ]]; then
	RUNNING=$(systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sed 's/\.service$//')

	for svc in $EXPECTED_SERVICES; do
		if [[ "$svc" == "ufw" ]]; then
			# ufw reports active via its own status text even when
			# systemctl shows "inactive (dead)" - rules run in-kernel.
			if ! ufw status | grep -q "Status: active"; then
				SERVICE_LINES="$SERVICE_LINES
[ERROR] ufw not active"
				STATUS=$LEVEL_ERROR
			fi
		elif [[ "$(systemctl is-active "$svc" 2>/dev/null)" != "active" ]]; then
			SERVICE_LINES="$SERVICE_LINES
[ERROR] $svc not active"
			STATUS=$LEVEL_ERROR
		fi
	done

	for svc in $RUNNING; do
		case " $EXPECTED_SERVICES " in
			*" $svc "*) ;;
			*)
				SERVICE_LINES="$SERVICE_LINES
[WARN] unexpected service running: $svc"
				[[ "$STATUS" -lt "$LEVEL_WARN" ]] && STATUS=$LEVEL_WARN
				;;
		esac
	done
fi

# --- Ports ---
if [[ "$CHECK_PORTS" == "yes" ]]; then
	LISTEN_RAW=$(ss -tln | grep LISTEN | awk '{print $4}')

	PUBLIC_LISTENING=""
	LOCAL_LISTENING=""
	for entry in $LISTEN_RAW; do
		port=${entry##*:}
		addr=${entry%:*}
		case "$addr" in
			127.*|\[::1\]|::1) LOCAL_LISTENING="$LOCAL_LISTENING $port" ;;
			*) PUBLIC_LISTENING="$PUBLIC_LISTENING $port" ;;
		esac
	done
	PUBLIC_LISTENING=$(tr ' ' '\n' <<< "$PUBLIC_LISTENING" | sort -un)
	LOCAL_LISTENING=$(tr ' ' '\n' <<< "$LOCAL_LISTENING" | sort -un)
	ALL_LISTENING=$(printf '%s\n%s' "$PUBLIC_LISTENING" "$LOCAL_LISTENING" | sort -un)

	for port in $EXPECTED_PORTS; do
		if ! grep -qx "$port" <<< "$ALL_LISTENING"; then
			PORT_LINES="$PORT_LINES
[ERROR] expected port $port not listening"
			STATUS=$LEVEL_ERROR
		fi
	done

	for port in $PUBLIC_LISTENING; do
		if [[ ! " $EXPECTED_PORTS " =~ " $port " ]]; then
			PORT_LINES="$PORT_LINES
[WARN] unexpected public port $port listening"
			[[ "$STATUS" -lt "$LEVEL_WARN" ]] && STATUS=$LEVEL_WARN
		fi
	done
fi

# --- Updates ---
if [[ "$CHECK_UPDATES" == "yes" ]]; then
	UPDATES=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
	if [[ "$UPDATES" -gt 0 ]]; then
		UPDATE_LINES="[WARN] $UPDATES packages upgradable"
		[[ "$STATUS" -lt "$LEVEL_WARN" ]] && STATUS=$LEVEL_WARN
	else
		UPDATE_LINES="none"
	fi
fi

case "$STATUS" in
	"$LEVEL_ERROR") SUBJECT_TAG="ERROR" ;;
	"$LEVEL_WARN")  SUBJECT_TAG="WARN" ;;
	*)              SUBJECT_TAG="OK" ;;
esac

REPORT=$(
	echo "=== Health Report $DATE ==="
	echo ""
	if [[ "$CHECK_DISK" == "yes" ]]; then
		echo "=== Disk Usage ==="
		df -h | grep -v tmpfs
		[[ -n "$DISK_LINES" ]] && echo "$DISK_LINES"
		echo ""
	fi
	echo "=== Memory / Load ==="
	free -h
	uptime
	echo ""
	if [[ "$CHECK_SERVICES" == "yes" ]]; then
		echo "=== Services ==="
		echo "Expected: $EXPECTED_SERVICES"
		[[ -n "$SERVICE_LINES" ]] && echo "$SERVICE_LINES" || echo "[OK] running services match expected"
		echo ""
	fi
	if [[ "$CHECK_PORTS" == "yes" ]]; then
		echo "=== Ports ==="
		echo "Expected: $EXPECTED_PORTS"
		echo "Public:   $(tr '\n' ' ' <<< "$PUBLIC_LISTENING")"
		echo "Local:    $(tr '\n' ' ' <<< "$LOCAL_LISTENING")"
		[[ -n "$PORT_LINES" ]] && echo "$PORT_LINES" || echo "[OK] matches expected ports"
		echo ""
	fi
	if [[ "$CHECK_UPDATES" == "yes" ]]; then
		echo "=== Updates ==="
		echo "$UPDATE_LINES"
	fi
	echo ""
	echo "-- lazy-admin-tools - dragons@work"
)

echo "$REPORT" | mail -s "[$SUBJECT_TAG] $HOSTNAME health report" "$MAILTO"
