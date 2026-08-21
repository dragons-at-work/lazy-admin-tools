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
#     reach the host - the ACME issue step remains the real proof. ---
DNS_TOOL=""
if command -v dig >/dev/null 2>&1; then
	DNS_TOOL=dig
elif command -v host >/dev/null 2>&1; then
	DNS_TOOL=host
fi

if [[ -n "$DNS_TOOL" ]]; then
	for name in "${NAMES[@]}"; do
		RESOLVED=""
		if [[ "$DNS_TOOL" == dig ]]; then
			RESOLVED="$(dig +short A "$name") $(dig +short AAAA "$name")"
		else
			RESOLVED="$(host "$name" 2>/dev/null || true)"
		fi
		if [[ -z "${RESOLVED// /}" ]]; then
			echo "[ERROR] no DNS A/AAAA record found for $name" >&2
			exit 1
		fi
	done
	echo "[OK] all names resolve in DNS"
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
