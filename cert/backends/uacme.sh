#!/bin/bash
# lazy-admin-tools: uacme backend for cert-add / cert-deploy / cert-renew / cert-del
# Usage (called by the cert-* frontends only):
#   uacme.sh add    <primary> [san...]
#   uacme.sh paths  <primary>
#   uacme.sh list
#   uacme.sh renew  <primary> [san...]
#   uacme.sh del    <primary>
#
# Owns everything uacme-specific: account bootstrap under /var/lib/uacme,
# the http-01 hook, the issue call, and where/how uacme stores its
# output. The frontends (cert-add, cert-deploy, cert-renew) do not know
# uacme's option syntax or on-disk layout - only this file does. In
# particular cert-renew.sh knows nothing about /var/lib/uacme: it asks
# this backend for the list of certificates it manages via "list".

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

SUBCOMMAND="${1:-}"
case "$SUBCOMMAND" in
	add|paths|renew|list|del) shift ;;
	*)
		echo "Usage: uacme.sh add|paths|renew|del <primary> [san...] | list" >&2
		exit 2
		;;
esac

# --- list: which certificates does this backend manage? One line per
#     certificate: "<primary> <san1> <san2> ...". No ACME calls, no
#     root/hook requirements - pure discovery, so cert-renew.sh never
#     needs to know where or how uacme stores anything. ---
if [[ "$SUBCOMMAND" == list ]]; then
	if [[ ! -d "$CONFDIR" ]]; then
		exit 0
	fi
	for cert_dir in "$CONFDIR"/*/; do
		[[ -d "$cert_dir" ]] || continue
		primary="$(basename "$cert_dir")"
		[[ "$primary" == private ]] && continue
		[[ -f "$cert_dir/cert.pem" ]] || continue
		sans="$(openssl x509 -in "$cert_dir/cert.pem" -noout -ext subjectAltName 2>/dev/null \
			| grep -o 'DNS:[^,]*' | sed 's/DNS://g' | grep -vx "$primary" | tr '\n' ' ' | xargs || true)"
		echo "$primary $sans"
	done
	exit 0
fi

if [[ $# -lt 1 ]]; then
	echo "[ERROR] at least one identifier required" >&2
	exit 2
fi

PRIMARY="$1"
shift
SANS=("$@")

# --- paths: pure lookup, no ACME calls, no root/hook requirements.
#     Prints "cert-path\nkey-path\n" for the given primary. Used by
#     cert-deploy to find what to copy, without cert-deploy needing
#     to know uacme's directory layout. ---
if [[ "$SUBCOMMAND" == paths ]]; then
	echo "$CONFDIR/$PRIMARY/cert.pem"
	echo "$CONFDIR/private/$PRIMARY/key.pem"
	exit 0
fi

# --- del: remove local ACME backend state only. Deliberately not a
#     revoke - revoking is a separate, more destructive operation
#     (e.g. for a compromised key) that a caller must request
#     explicitly and is not implemented here. No ACME calls, no
#     hook/account requirements - this is pure local cleanup. ---
if [[ "$SUBCOMMAND" == del ]]; then
	if [[ ! -d "$CONFDIR/$PRIMARY" && ! -d "$CONFDIR/private/$PRIMARY" ]]; then
		echo "[ERROR] no local state found for $PRIMARY under $CONFDIR" >&2
		exit 1
	fi
	rm -rf "$CONFDIR/$PRIMARY" "$CONFDIR/private/$PRIMARY"
	echo "[OK] removed local ACME state: $PRIMARY"
	exit 0
fi

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

if [[ "$SUBCOMMAND" == renew ]]; then
	# Renewal is unattended (cron): never prompt for an account email.
	if [[ ! -f "$CONFDIR/private/key.pem" ]]; then
		echo "[ERROR] no ACME account found under $CONFDIR - run 'cert-add' interactively first" >&2
		exit 1
	fi

	CERT_FILE="$CONFDIR/$PRIMARY/cert.pem"
	BEFORE_HASH=""
	[[ -f "$CERT_FILE" ]] && BEFORE_HASH="$(sha256sum "$CERT_FILE" | awk '{print $1}')"

	echo "[INFO] checking certificate: $PRIMARY ${SANS[*]-}"
	set +e
	ISSUE_OUTPUT=$(sudo -u "$UACME_USER" uacme -v -c "$CONFDIR" -h "$HOOK" issue "$PRIMARY" "${SANS[@]}" 2>&1)
	ISSUE_EXIT=$?
	set -e
	echo "$ISSUE_OUTPUT"

	# uacme exits non-zero both on a real failure AND on its normal
	# "not due for renewal yet" skip - the exit code alone cannot tell
	# these apart. The certificate file itself is the actual source of
	# truth for whether anything changed; a non-zero exit is only
	# treated as fatal here if the file did NOT change AND uacme's own
	# output does not look like a deliberate skip.
	AFTER_HASH=""
	[[ -f "$CERT_FILE" ]] && AFTER_HASH="$(sha256sum "$CERT_FILE" | awk '{print $1}')"

	if [[ -n "$AFTER_HASH" && "$AFTER_HASH" != "$BEFORE_HASH" ]]; then
		echo "[OK] certificate renewed: $PRIMARY"
		echo "RENEWED=yes"
	elif [[ "$ISSUE_EXIT" -eq 0 ]] || echo "$ISSUE_OUTPUT" | grep -qi "skipping"; then
		echo "[OK] certificate still valid, no renewal needed: $PRIMARY"
		echo "RENEWED=no"
	else
		echo "[ERROR] uacme issue failed for $PRIMARY" >&2
		exit 1
	fi
	exit 0
fi

# --- add: interactive/first-time issuance, with account bootstrap ---

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
