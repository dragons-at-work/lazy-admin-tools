#!/bin/bash
# lazy-admin-tools: uacme backend for cert-add
# Usage (called by cert-add.sh only): uacme.sh add <primary> [san...]
#
# Owns everything uacme-specific: account bootstrap under /var/lib/uacme,
# the http-01 hook, and the issue call. cert-add.sh does not know uacme
# option syntax - only this file does.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
CONFDIR=/var/lib/uacme
CHALLENGE_DIR=/var/www/acme-challenge/.well-known/acme-challenge
UACME_USER=uacme
# --- End configuration ---

BACKEND_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOOK="$(cd "$BACKEND_DIR/../hooks" && pwd)/uacme-http-01.sh"

if [[ "${1:-}" != "add" ]]; then
	echo "Usage: uacme.sh add <primary> [san...]" >&2
	exit 2
fi
shift

if [[ $# -lt 1 ]]; then
	echo "[ERROR] at least one identifier required" >&2
	exit 2
fi

PRIMARY="$1"
shift
SANS=("$@")

if ! command -v uacme >/dev/null 2>&1; then
	echo "[ERROR] uacme not installed" >&2
	exit 1
fi

if [[ ! -x "$HOOK" ]]; then
	echo "[ERROR] hook not found or not executable: $HOOK" >&2
	exit 1
fi

if ! id "$UACME_USER" >/dev/null 2>&1; then
	echo "[ERROR] system user not found: $UACME_USER" >&2
	exit 1
fi

if [[ ! -d "$CHALLENGE_DIR" ]]; then
	echo "[ERROR] challenge directory not found: $CHALLENGE_DIR" >&2
	exit 1
fi

# Hook must actually be able to write and remove a file in the
# challenge dir as the uacme user - prove it now, not mid-issue.
PROBE_TOKEN="preflight-$$-$RANDOM"
if ! sudo -u "$UACME_USER" "$HOOK" begin http-01 "$PRIMARY" "$PROBE_TOKEN" "probe" >/dev/null 2>&1; then
	echo "[ERROR] hook could not write challenge file as $UACME_USER" >&2
	exit 1
fi
if [[ ! -f "$CHALLENGE_DIR/$PROBE_TOKEN" ]]; then
	echo "[ERROR] hook reported success but challenge file is missing" >&2
	exit 1
fi
sudo -u "$UACME_USER" "$HOOK" done http-01 "$PRIMARY" "$PROBE_TOKEN" "probe" >/dev/null 2>&1 || true
if [[ -f "$CHALLENGE_DIR/$PROBE_TOKEN" ]]; then
	echo "[ERROR] hook could not remove challenge file as $UACME_USER" >&2
	exit 1
fi
echo "[OK] local HTTP-01 challenge path works"

# --- Account bootstrap ---
if [[ ! -f "$CONFDIR/private/key.pem" ]]; then
	echo "[INFO] no ACME account found under $CONFDIR"

	EMAIL="${ACME_ACCOUNT_EMAIL:-}"
	if [[ -z "$EMAIL" ]]; then
		if [[ ! -t 0 ]]; then
			echo "[ERROR] ACME account does not exist and ACME_ACCOUNT_EMAIL is not set (no terminal to prompt)" >&2
			exit 1
		fi
		read -r -p "ACME account email: " EMAIL
	fi

	if ! [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
		echo "[ERROR] not a valid email address: $EMAIL" >&2
		exit 1
	fi

	mkdir -p "$CONFDIR"
	chown "$UACME_USER:$UACME_USER" "$CONFDIR"
	echo "[INFO] creating ACME account for $EMAIL"
	if ! sudo -u "$UACME_USER" uacme -v -c "$CONFDIR" -y new "$EMAIL"; then
		echo "[ERROR] failed to create ACME account" >&2
		exit 1
	fi
	echo "[OK] ACME account created"
else
	echo "[OK] ACME account already present"
fi

# --- Issue ---
echo "[INFO] requesting certificate: $PRIMARY ${SANS[*]-}"
if ! sudo -u "$UACME_USER" uacme -v -c "$CONFDIR" -h "$HOOK" issue "$PRIMARY" "${SANS[@]}"; then
	echo "[ERROR] uacme issue failed for $PRIMARY" >&2
	exit 1
fi

echo "[OK] certificate created: $CONFDIR/$PRIMARY/"
