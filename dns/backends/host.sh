#!/bin/bash
# lazy-admin-tools: host backend for dns-domain-info
# Usage (called by dns-domain-info.sh only):
#   host.sh ns <domain>
#   host.sh query <type> <name> [nameserver]
#
# Owns everything host(1)-specific: command syntax, exit-code quirks,
# and telling "no record" apart from a real query failure. The
# frontend does not parse host's output format - only this file does.
#
# Proven on Debian 13 (terrador). Not yet proven on OpenBSD - do not
# assume host(1) exists there; a drill.sh backend is a separate,
# not-yet-built candidate (see cert/backends/ for the same pattern
# with acme-client).

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if ! command -v host >/dev/null 2>&1; then
	echo "[ERROR] host(1) not installed" >&2
	exit 1
fi

SUBCOMMAND="${1:-}"
case "$SUBCOMMAND" in
	ns|query) shift ;;
	*)
		echo "Usage: host.sh ns <domain> | query <type> <name> [nameserver]" >&2
		exit 2
		;;
esac

# --- ns: authoritative nameservers for a domain, walking up labels
#     until an NS record is found. One hostname per line, no trailing
#     dot. Empty output (exit 0) if none could be determined at all -
#     the frontend decides whether that itself is worth flagging. ---
if [[ "$SUBCOMMAND" == ns ]]; then
	if [[ $# -ne 1 ]]; then
		echo "[ERROR] ns requires exactly one domain" >&2
		exit 2
	fi
	domain="$1"
	while [[ "$domain" == *.* ]]; do
		result="$(host -t NS "$domain" 2>/dev/null | awk '/name server/ {print $NF}' | sed 's/\.$//')"
		if [[ -n "$result" ]]; then
			echo "$result"
			exit 0
		fi
		domain="${domain#*.}"
	done
	exit 0
fi

# --- query: records of <type> for <name>, optionally against a
#     specific nameserver. One record per line, generic across types:
#     the line after the leading "<name> " is printed as-is, which
#     works for host's "has address", "has SOA record", "mail is
#     handled by", "has SRV record", etc. without per-type parsing.
#
#     Empty output + exit 0 = no record (NXDOMAIN or "no <type>
#     record" - both are normal information here, not an error).
#     Exit 1 = a real query/network failure (timeout, no servers
#     reachable, ...), distinguished by host's own wording. ---
if [[ "$SUBCOMMAND" == query ]]; then
	if [[ $# -lt 2 || $# -gt 3 ]]; then
		echo "[ERROR] query requires <type> <name> [nameserver]" >&2
		exit 2
	fi
	type="$1"
	name="$2"
	ns="${3:-}"

	set +e
	if [[ -n "$ns" ]]; then
		output="$(host -t "$type" "$name" "$ns" 2>&1)"
	else
		output="$(host -t "$type" "$name" 2>&1)"
	fi
	exit_code=$?
	set -e

	if [[ "$exit_code" -eq 0 ]]; then
		echo "$output" | sed -n "s/^$name //p"
		exit 0
	fi

	# Known "no record" phrasings from host(1) - informational, not
	# an error. Anything else with a non-zero exit is treated as a
	# real failure so it doesn't silently look like "record absent".
	if echo "$output" | grep -qiE "not found|does not exist|no ${type} record"; then
		exit 0
	fi

	echo "[ERROR] host query failed for $type $name${ns:+ @$ns}: $output" >&2
	exit 1
fi
