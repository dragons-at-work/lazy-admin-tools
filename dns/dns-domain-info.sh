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

if ! NS_LIST="$("$BACKEND_BIN" ns "$DOMAIN")"; then
	echo "[ERROR] failed to determine authoritative nameservers for $DOMAIN" >&2
	exit 1
fi
NS_LIST="$(echo "$NS_LIST" | sort -u)"
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
	declare -A group=()   # canon -> "ns1 ns2 ..."
	FAILED=no
	while IFS= read -r ns; do
		[[ -z "$ns" ]] && continue
		if ! result="$("$BACKEND_BIN" query "$type" "$name" "$ns" 2>&1)"; then
			echo "  [ERROR] $ns: $result"
			FAILED=yes
			continue
		fi
		if [[ -z "$result" ]]; then
			canon="__EMPTY__"
		else
			# Record-Reihenfolge ist nicht semantisch - vor dem
			# Vergleich sortieren, sonst gilt dieselbe Menge in
			# anderer Reihenfolge faelschlich als abweichend.
			canon="$(echo "$result" | sort -u)"
		fi
		group["$canon"]="${group[$canon]:-}$ns "
	done <<< "$NS_LIST"

	# Gleiche Antwort einmal zeigen, mit allen NS die sie geliefert
	# haben - statt sie pro NS zu wiederholen.
	for canon in "${!group[@]}"; do
		nslist="${group[$canon]% }"
		echo "  ${nslist// /, }:"
		if [[ "$canon" == __EMPTY__ ]]; then
			echo "    (kein Record)"
		else
			echo "$canon" | while IFS= read -r line; do
				echo "    $line"
			done
		fi
	done

	if [[ "$FAILED" == no && "${#group[@]}" -gt 1 ]]; then
		echo "  [WARN] Nameserver antworten unterschiedlich"
	fi
	unset group
	echo ""
done

echo "-- lazy-admin-tools - dragons@work"
