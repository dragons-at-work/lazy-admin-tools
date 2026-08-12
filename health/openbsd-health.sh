#!/bin/sh
# lazy-admin-tools: OpenBSD Health Check
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
#   rcctl ls started
# Example only - replace with your real service list.
EXPECTED_SERVICES="httpd relayd smtpd sshd"

CHECK_PORTS=yes
EXPECTED_PORTS="22 80 443"

CHECK_PATCHES=yes

# --- End configuration ---

HOSTNAME=$(hostname -s)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$(id -u)" -ne 0 ]; then
	echo "=== Health Report $DATE ===

[ERROR] script must run as root (rcctl/syspatch need root privileges)" | mail -s "[ERROR] $HOSTNAME health report" "$MAILTO"
	exit 1
fi

LEVEL_OK=0
LEVEL_WARN=1
LEVEL_ERROR=2
STATUS=$LEVEL_OK

DISK_LINES=""
SERVICE_LINES=""
PORT_LINES=""
PATCH_LINES=""

# --- Disk ---
if [ "$CHECK_DISK" = "yes" ]; then
	DISK_LINES=$(df -h | grep -v tmpfs | awk -v warn="$DISK_WARN_PCT" -v err="$DISK_ERROR_PCT" '
		NR>1 {
			pct=$5; gsub(/%/,"",pct)
			if (pct+0 >= err)      print "[ERROR] " $6 " " $5 " full"
			else if (pct+0 >= warn) print "[WARN] " $6 " " $5 " full"
		}')
	if echo "$DISK_LINES" | grep -q "\[ERROR\]"; then STATUS=$LEVEL_ERROR
	elif echo "$DISK_LINES" | grep -q "\[WARN\]" && [ "$STATUS" -lt "$LEVEL_WARN" ]; then STATUS=$LEVEL_WARN
	fi
fi

# --- Services ---
if [ "$CHECK_SERVICES" = "yes" ]; then
	STARTED=$(rcctl ls started)
	for svc in $EXPECTED_SERVICES; do
		if ! echo "$STARTED" | grep -q "^${svc}$"; then
			SERVICE_LINES="$SERVICE_LINES
[ERROR] $svc not running"
			STATUS=$LEVEL_ERROR
		fi
	done
	for svc in $STARTED; do
		case " $EXPECTED_SERVICES " in
			*" $svc "*) ;;
			*)
				SERVICE_LINES="$SERVICE_LINES
[WARN] unexpected service running: $svc"
				[ "$STATUS" -lt "$LEVEL_WARN" ] && STATUS=$LEVEL_WARN
				;;
		esac
	done
fi

# --- Ports ---
if [ "$CHECK_PORTS" = "yes" ]; then
	LISTEN_RAW=$( { netstat -an -f inet 2>/dev/null | grep LISTEN; netstat -an -f inet6 2>/dev/null | grep LISTEN; } | awk '{print $4}')

	PUBLIC_LISTENING=""
	LOCAL_LISTENING=""
	for entry in $LISTEN_RAW; do
		port=${entry##*.}
		addr=${entry%.*}
		case "$addr" in
			127.*|::1|*%lo0|*%lo) LOCAL_LISTENING="$LOCAL_LISTENING $port" ;;
			*) PUBLIC_LISTENING="$PUBLIC_LISTENING $port" ;;
		esac
	done
	PUBLIC_LISTENING=$(echo $PUBLIC_LISTENING | tr ' ' '\n' | sort -un)
	LOCAL_LISTENING=$(echo $LOCAL_LISTENING | tr ' ' '\n' | sort -un)
	ALL_LISTENING=$(printf '%s\n%s' "$PUBLIC_LISTENING" "$LOCAL_LISTENING" | sort -un)

	for port in $EXPECTED_PORTS; do
		if ! echo "$ALL_LISTENING" | grep -qx "$port"; then
			PORT_LINES="$PORT_LINES
[ERROR] expected port $port not listening"
			STATUS=$LEVEL_ERROR
		fi
	done

	for port in $PUBLIC_LISTENING; do
		case " $EXPECTED_PORTS " in
			*" $port "*) ;;
			*)
				PORT_LINES="$PORT_LINES
[WARN] unexpected public port $port listening"
				[ "$STATUS" -lt "$LEVEL_WARN" ] && STATUS=$LEVEL_WARN
				;;
		esac
	done
fi

# --- Patches ---
if [ "$CHECK_PATCHES" = "yes" ]; then
	PATCHES=$(syspatch -c 2>&1)
	if [ -n "$PATCHES" ]; then
		PATCH_LINES="[WARN] pending: $(echo "$PATCHES" | tr '\n' ' ')"
		[ "$STATUS" -lt "$LEVEL_WARN" ] && STATUS=$LEVEL_WARN
	else
		PATCH_LINES="none"
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
	if [ "$CHECK_DISK" = "yes" ]; then
		echo "=== Disk Usage ==="
		df -h | grep -v tmpfs
		[ -n "$DISK_LINES" ] && echo "$DISK_LINES"
		echo ""
	fi
	echo "=== Memory / Load ==="
	uptime
	echo ""
	if [ "$CHECK_SERVICES" = "yes" ]; then
		echo "=== Services ==="
		echo "Expected: $EXPECTED_SERVICES"
		[ -n "$SERVICE_LINES" ] && echo "$SERVICE_LINES" || echo "[OK] running services match expected"
		echo ""
	fi
	if [ "$CHECK_PORTS" = "yes" ]; then
		echo "=== Ports ==="
		echo "Expected: $EXPECTED_PORTS"
		echo "Public:   $(echo "$PUBLIC_LISTENING" | tr '\n' ' ')"
		echo "Local:    $(echo "$LOCAL_LISTENING" | tr '\n' ' ')"
		[ -n "$PORT_LINES" ] && echo "$PORT_LINES" || echo "[OK] matches expected ports"
		echo ""
	fi
	if [ "$CHECK_PATCHES" = "yes" ]; then
		echo "=== Pending Patches ==="
		echo "$PATCH_LINES"
	fi
	echo ""
	echo "-- lazy-admin-tools - dragons@work"
)

echo "$REPORT" | mail -s "[$SUBJECT_TAG] $HOSTNAME health report" "$MAILTO"
