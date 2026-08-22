#!/bin/bash
# lazy-admin-tools: cert-add - request a TLS certificate (any backend)
# Usage: cert-add [--backend uacme|acme-client] <primary-name> [san-name ...]
#
# Frontend only: argument parsing, common validation (domain syntax,
# DNS resolution, root check), backend detection, and a uniform
# success/failure message. All engine-specific behaviour (account
# state, hook, actual issue command) lives in backends/<name>.sh.
#
# v1 supports uacme only. acme-client (OpenBSD) is a planned backend -
# selecting it explicitly fails clearly until backends/acme-client.sh
# exists; it is deliberately not offered by auto-detection yet.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backends"

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

BACKEND=""
if [[ "${1:-}" == "--backend" ]]; then
	if [[ $# -lt 3 || -z "${2:-}" ]]; then
		echo "Usage: cert-add [--backend uacme|acme-client] <primary-name> [san-name ...]" >&2
		exit 2
	fi
	BACKEND="$2"
	shift 2
fi

if [[ $# -lt 1 ]]; then
	echo "Usage: cert-add [--backend uacme|acme-client] <primary-name> [san-name ...]" >&2
	exit 2
fi

NAMES=("$@")

# --- Validate all identifiers up front ---
for name in "${NAMES[@]}"; do
	if ! [[ "$name" =~ $DOMAIN_RE ]]; then
		echo "[ERROR] not a valid domain name: $name" >&2
		exit 1
	fi
done

# --- DNS preflight: can only warn about what we can actually check.
#     A successful local resolution does not prove Let's Encrypt can
#     reach the host - the ACME issue step remains the real proof.
#
#     The system/local resolver alone is not reliable enough for this
#     check: a caching or split-horizon resolver can report a name as
#     resolving even when the domain's own authoritative nameservers
#     do not have a record for it - which is exactly what Let's
#     Encrypt's validation sees. So beyond the local resolver, this
#     also queries the name's authoritative nameservers directly
#     (found by walking up from the full name to its registrable
#     domain) and requires the record to exist there too. ---
DNS_TOOL=""
if command -v dig >/dev/null 2>&1; then
	DNS_TOOL=dig
elif command -v host >/dev/null 2>&1; then
	DNS_TOOL=host
fi

# Find authoritative nameservers for a name by walking up its labels
# until an NS record is found. Prints nameserver hostnames, one per
# line, or nothing if none could be determined. Works with either
# tool, since dig is not guaranteed to be installed (it is not, on
# some real hosts this runs on).
find_authoritative_ns() {
	local fqdn="$1"
	local tool="$2"
	local domain="$fqdn"
	while [[ "$domain" == *.* ]]; do
		local ns
		if [[ "$tool" == dig ]]; then
			ns=$(dig +short NS "$domain" 2>/dev/null)
		else
			ns=$(host -t NS "$domain" 2>/dev/null | awk '/name server/ {print $NF}' | sed 's/\.$//')
		fi
		if [[ -n "$ns" ]]; then
			echo "$ns"
			return 0
		fi
		domain="${domain#*.}"
	done
	return 1
}

# Query a specific nameserver directly for a name's A/AAAA records.
# Returns success (name found there) via exit status, tool-neutral.
query_authoritative() {
	local name="$1"
	local ns="$2"
	local tool="$3"
	if [[ "$tool" == dig ]]; then
		local result
		result="$(dig +short A "$name" "@$ns") $(dig +short AAAA "$name" "@$ns")"
		[[ -n "${result// /}" ]]
	else
		host "$name" "$ns" >/dev/null 2>&1
	fi
}

if [[ -n "$DNS_TOOL" ]]; then
	for name in "${NAMES[@]}"; do
		if [[ "$DNS_TOOL" == dig ]]; then
			RESOLVED="$(dig +short A "$name") $(dig +short AAAA "$name")"
			if [[ -z "${RESOLVED// /}" ]]; then
				echo "[ERROR] no DNS A/AAAA record found for $name" >&2
				exit 1
			fi
		else
			# host's own "not found" message is non-empty text on
			# stdout, not an empty result - a plain "output is empty"
			# check treats that message itself as a successful
			# resolution. Use host's exit status instead (0 = found,
			# non-zero = NXDOMAIN/SERVFAIL/etc.) - confirmed for real:
			# a name with no DNS record at all was reported as
			# resolving by this check before the fix.
			if ! host "$name" >/dev/null 2>&1; then
				echo "[ERROR] no DNS A/AAAA record found for $name" >&2
				exit 1
			fi
		fi

		AUTH_NS_LIST="$(find_authoritative_ns "$name" "$DNS_TOOL" || true)"
		if [[ -n "$AUTH_NS_LIST" ]]; then
			AUTH_OK=no
			while IFS= read -r ns; do
				[[ -z "$ns" ]] && continue
				if query_authoritative "$name" "$ns" "$DNS_TOOL"; then
					AUTH_OK=yes
					break
				fi
			done <<< "$AUTH_NS_LIST"
			if [[ "$AUTH_OK" != yes ]]; then
				echo "[ERROR] $name resolves via the local resolver, but not via its own authoritative nameservers - DNS is likely not live yet or not propagated" >&2
				exit 1
			fi
		fi
	done
	echo "[OK] all names resolve in DNS (local and authoritative)"
else
	echo "[WARN] no dig/host available - skipping DNS preflight" >&2
fi

# --- Backend selection ---
HAVE_UACME=no
HAVE_ACME_CLIENT=no
command -v uacme >/dev/null 2>&1 && HAVE_UACME=yes
command -v acme-client >/dev/null 2>&1 && HAVE_ACME_CLIENT=yes

if [[ -z "$BACKEND" ]]; then
	if [[ "$HAVE_UACME" == yes && "$HAVE_ACME_CLIENT" == yes ]]; then
		echo "[ERROR] both uacme and acme-client found - specify --backend explicitly" >&2
		exit 1
	elif [[ "$HAVE_UACME" == yes ]]; then
		BACKEND=uacme
	elif [[ "$HAVE_ACME_CLIENT" == yes ]]; then
		BACKEND=acme-client
	else
		echo "[ERROR] neither uacme nor acme-client found" >&2
		exit 1
	fi
fi

BACKEND_SCRIPT="$BACKEND_DIR/$BACKEND.sh"
if [[ ! -x "$BACKEND_SCRIPT" ]]; then
	echo "[ERROR] backend not available yet: $BACKEND ($BACKEND_SCRIPT not found or not executable)" >&2
	exit 1
fi

echo "[INFO] using backend: $BACKEND"

if ! "$BACKEND_SCRIPT" add "${NAMES[@]}"; then
	echo "[ERROR] cert-add failed for ${NAMES[0]}" >&2
	exit 1
fi

echo "[OK] cert-add complete: ${NAMES[0]}"
echo ""
echo "-- lazy-admin-tools - dragons@work"
