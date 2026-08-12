#!/bin/bash
# lazy-admin-tools: Debian Health Check
# Runs daily via cron, sends report via mail.

# --- Configuration ---
MAILTO="root"

CHECK_DISK=yes
DISK_WARN_PCT=80
DISK_ERROR_PCT=95

CHECK_SERVICES=yes
# Complete list of services expected to be running - any running
# service not listed here triggers a WARN, so this must be your full
# baseline, not just the services you care about. Before first use,
# determine your actual baseline with:
#   systemctl list-units --type=service --state=running --no-legend
# Example only - replace with your real service list.
EXPECTED_SERVICES="ssh ufw fail2ban"

CHECK_PORTS=yes
# Example only - the SSH port you actually use, plus any public services.
EXPECTED_PORTS="22"

CHECK_UPDATES=yes

# --- End configuration ---

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
