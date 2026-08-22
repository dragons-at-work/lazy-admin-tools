#!/bin/bash
# lazy-admin-tools: cert-renew - renew all known certificates (cron-friendly)
# Usage: cert-renew [--backend uacme]
#
# Backend-agnostic: asks the backend which certificates it manages via
# "list" (one "<primary> <san...>" line per certificate) rather than
# knowing any backend's storage layout. For each one, asks the backend
# to "renew" (the ACME client itself decides whether a renewal is
# actually due; the backend reports RENEWED=yes/no based on whether
# the certificate file actually changed), and deploys + reloads only
# the ones that changed. cert-deploy is idempotent on its own, but
# skipping the call entirely when nothing renewed keeps cron logs
# quiet on the common case (nothing due).
#
# Per-certificate reload targets are read from an optional manifest:
#   /etc/cert-deploy/<primary-name>.services
# One service name per line, comments (#) and blank lines ignored.
# No manifest means: deploy files, restart nothing.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backends"

# --- Configuration ---
SERVICES_MANIFEST_DIR=/etc/cert-deploy
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

BACKEND=""
if [[ "${1:-}" == "--backend" ]]; then
	if [[ $# -lt 2 || -z "${2:-}" ]]; then
		echo "Usage: cert-renew [--backend uacme]" >&2
		exit 2
	fi
	BACKEND="$2"
	shift 2
fi

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
	echo "[ERROR] backend not available: $BACKEND ($BACKEND_SCRIPT not found or not executable)" >&2
	exit 1
fi

LIST_OUTPUT=$("$BACKEND_SCRIPT" list) || {
	echo "[ERROR] backend list failed" >&2
	exit 1
}

FAILED=no
FOUND_ANY=no

while IFS= read -r line || [[ -n "$line" ]]; do
	[[ -z "$line" ]] && continue
	FOUND_ANY=yes

	PRIMARY="${line%% *}"
	SANS_LIST="${line#"$PRIMARY"}"
	SANS_LIST="${SANS_LIST# }"
	[[ "$SANS_LIST" == "$line" ]] && SANS_LIST=""

	echo "=== $PRIMARY ==="

	RENEW_OUTPUT=$("$BACKEND_SCRIPT" renew "$PRIMARY" $SANS_LIST) || {
		echo "[ERROR] renewal failed for $PRIMARY" >&2
		FAILED=yes
		continue
	}
	echo "$RENEW_OUTPUT"

	if ! echo "$RENEW_OUTPUT" | grep -q "^RENEWED=yes$"; then
		continue
	fi

	MANIFEST="$SERVICES_MANIFEST_DIR/$PRIMARY.services"
	SERVICES=()
	if [[ -f "$MANIFEST" ]]; then
		while IFS= read -r svc || [[ -n "$svc" ]]; do
			[[ -z "$svc" || "$svc" == \#* ]] && continue
			SERVICES+=("$svc")
		done < "$MANIFEST"
	fi

	if ! "$SCRIPT_DIR/cert-deploy.sh" --backend "$BACKEND" "$PRIMARY" "${SERVICES[@]}"; then
		echo "[ERROR] deploy failed for $PRIMARY" >&2
		FAILED=yes
	fi
done <<< "$LIST_OUTPUT"

if [[ "$FOUND_ANY" == no ]]; then
	echo "[INFO] backend reports no certificates to renew"
fi

if [[ "$FAILED" == yes ]]; then
	exit 1
fi

echo ""
echo "-- lazy-admin-tools - dragons@work"
