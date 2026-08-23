#!/bin/bash
# lazy-admin-tools: dns-domain-info - authoritative DNS state of a domain
# Usage: dns-domain-info.sh [--backend host] <domain>
#
# Frontend only: which records to ask for, which nameservers to ask,
# and how to show what came back - including disagreement between
# nameservers. All tool-specific query syntax lives in backends/<n>.sh
# (see backends/host.sh). This is an information tool, not a
# validator: it does not judge whether the result is "correct" and it
# never changes DNS. A missing record is normal output, not a fatal
# error - only an actual query/network failure is.
#
# v1 supports the host backend only (proven on Debian). Selecting
# --backend drill fails clearly until backends/drill.sh exists - it
# is deliberately not offered by auto-detection yet (same pattern as
# cert-add.sh and acme-client).

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backends"

BACKEND=host
if [[ "${1:-}" == "--backend" ]]; then
	if [[ $# -lt 3 || -z "${2:-}" ]]; then
		echo "Usage: dns-domain-info.sh [--backend host] <domain>" >&2
		exit 2
	fi
	BACKEND="$2"
	shift 2
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: dns-domain-info.sh [--backend host] <domain>" >&2
	exit 2
fi
DOMAIN="$1"

BACKEND_BIN="$BACKEND_DIR/$BACKEND.sh"
if [[ ! -x "$BACKEND_BIN" ]]; then
	echo "[ERROR] backend not available: $BACKEND ($BACKEND_BIN not found)" >&2
	exit 1
fi

# --- Records to check for the mail-migration use case. Format:
#     "<name-template> <type>", where {d} is replaced with $DOMAIN. ---
RECORDS=(
	"{d} SOA"
	"{d} NS"
	"{d} A"
	"{d} AAAA"
	"{d} MX"
	"{d} TXT"
	"mail.{d} A"
	"mail.{d} AAAA"
	"imap.{d} A"
	"imap.{d} AAAA"
	"smtp.{d} A"
	"smtp.{d} AAAA"
	"autoconfig.{d} A"
	"autoconfig.{d} AAAA"
	"_dmarc.{d} TXT"
	"mail._domainkey.{d} TXT"
	"default._domainkey.{d} TXT"
	"_submission._tcp.{d} SRV"
	"_imaps._tcp.{d} SRV"
)

echo "=== $DOMAIN (backend: $BACKEND) ==="
echo ""

NS_LIST="$("$BACKEND_BIN" ns "$DOMAIN" || true)"
if [[ -z "$NS_LIST" ]]; then
	echo "[WARN] no authoritative nameservers found for $DOMAIN"
	echo "-- lazy-admin-tools - dragons@work"
	exit 0
fi

echo "-- Authoritative nameservers --"
echo "$NS_LIST"
echo ""

for entry in "${RECORDS[@]}"; do
	name_template="${entry% *}"
	type="${entry##* }"
	name="${name_template//\{d\}/$DOMAIN}"

	echo "-- $name $type --"
	declare -A seen=()
	FAILED=no
	while IFS= read -r ns; do
		[[ -z "$ns" ]] && continue
		if ! result="$("$BACKEND_BIN" query "$type" "$name" "$ns" 2>&1)"; then
			echo "  [ERROR] $ns: $result"
			FAILED=yes
			continue
		fi
		if [[ -z "$result" ]]; then
			echo "  $ns: (kein Record)"
			canon="__EMPTY__"
		else
			echo "$result" | while IFS= read -r line; do
				echo "  $ns: $line"
			done
			# Record-Reihenfolge ist nicht semantisch - vor dem
			# Vergleich sortieren, sonst gilt dieselbe Menge in
			# anderer Reihenfolge faelschlich als abweichend.
			canon="$(echo "$result" | sort -u)"
		fi
		seen["$canon"]=1
	done <<< "$NS_LIST"

	if [[ "$FAILED" == no && "${#seen[@]}" -gt 1 ]]; then
		echo "  [WARN] Nameserver antworten unterschiedlich"
	fi
	unset seen
	echo ""
done

echo "-- lazy-admin-tools - dragons@work"
