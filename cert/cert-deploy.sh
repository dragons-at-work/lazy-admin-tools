#!/bin/bash
# lazy-admin-tools: cert-deploy - install a certificate for its consumers
# Usage: cert-deploy [--backend uacme] <primary-name> [service ...]
#
# Copies the certificate and key from wherever the ACME backend stores
# them into a service-neutral location, then optionally restarts the
# given services. Backend-agnostic: asks backends/<name>.sh where the
# files live via "paths <primary>" rather than hardcoding uacme's
# layout here.
#
# Idempotent: if the destination cert already matches the source, no
# files are touched and no service is restarted. This makes cert-deploy
# safe to call from cert-renew after every renewal attempt, whether or
# not a renewal actually happened.
#
# Destination layout:
#   /etc/ssl/local/<primary-name>/cert.pem   (0644 root:root)
#   /etc/ssl/local/<primary-name>/key.pem    (0600 root:root)

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backends"

# --- Configuration ---
DEST_ROOT=/etc/ssl/local
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

BACKEND=""
if [[ "${1:-}" == "--backend" ]]; then
	if [[ $# -lt 3 || -z "${2:-}" ]]; then
		echo "Usage: cert-deploy [--backend uacme] <primary-name> [service ...]" >&2
		exit 2
	fi
	BACKEND="$2"
	shift 2
fi

if [[ $# -lt 1 ]]; then
	echo "Usage: cert-deploy [--backend uacme] <primary-name> [service ...]" >&2
	exit 2
fi

PRIMARY="$1"
shift
SERVICES=("$@")

# --- Backend selection: same auto-detect logic as cert-add ---
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

PATHS_OUTPUT=$("$BACKEND_SCRIPT" paths "$PRIMARY")
SRC_CERT=$(echo "$PATHS_OUTPUT" | sed -n '1p')
SRC_KEY=$(echo "$PATHS_OUTPUT" | sed -n '2p')

if [[ -z "$SRC_CERT" || -z "$SRC_KEY" ]]; then
	echo "[ERROR] backend did not return cert/key paths for $PRIMARY" >&2
	exit 1
fi

if [[ ! -f "$SRC_CERT" ]]; then
	echo "[ERROR] source certificate not found: $SRC_CERT - run cert-add first" >&2
	exit 1
fi
if [[ ! -f "$SRC_KEY" ]]; then
	echo "[ERROR] source key not found: $SRC_KEY - run cert-add first" >&2
	exit 1
fi

# --- Sanity check: certificate and key must actually belong together.
#     Comparing existence and byte content is not enough - a corrupted
#     or mismatched backend state could still pass those checks. Public
#     key comparison catches a cert/key pair that does not match, for
#     both RSA and EC keys. ---
CERT_PUBKEY="$(openssl x509 -in "$SRC_CERT" -noout -pubkey 2>/dev/null || true)"
KEY_PUBKEY="$(openssl pkey -in "$SRC_KEY" -pubout 2>/dev/null || true)"
if [[ -z "$CERT_PUBKEY" || -z "$KEY_PUBKEY" ]]; then
	echo "[ERROR] could not read public key from certificate or key file - refusing to deploy" >&2
	exit 1
fi
if [[ "$CERT_PUBKEY" != "$KEY_PUBKEY" ]]; then
	echo "[ERROR] certificate and key do not match (public key mismatch) - refusing to deploy: $SRC_CERT / $SRC_KEY" >&2
	exit 1
fi

DEST_DIR="$DEST_ROOT/$PRIMARY"
DEST_CERT="$DEST_DIR/cert.pem"
DEST_KEY="$DEST_DIR/key.pem"

# --- Idempotency check: skip entirely if nothing changed. Both cert
#     and key must match - a matching cert alone does not prove the
#     key is intact or was not swapped out independently. ---
if [[ -f "$DEST_CERT" && -f "$DEST_KEY" ]] \
	&& cmp -s "$SRC_CERT" "$DEST_CERT" \
	&& cmp -s "$SRC_KEY" "$DEST_KEY"; then
	echo "[OK] certificate and key already up to date: $DEST_DIR"
	exit 0
fi

mkdir -p "$DEST_DIR"
chmod 755 "$DEST_DIR"

TMP_CERT=$(mktemp "$DEST_DIR/.cert.XXXXXX")
TMP_KEY=$(mktemp "$DEST_DIR/.key.XXXXXX")
cleanup() { rm -f "$TMP_CERT" "$TMP_KEY"; }
trap cleanup EXIT

cp "$SRC_CERT" "$TMP_CERT"
cp "$SRC_KEY" "$TMP_KEY"
chown root:root "$TMP_CERT" "$TMP_KEY"
chmod 644 "$TMP_CERT"
chmod 600 "$TMP_KEY"

mv "$TMP_CERT" "$DEST_CERT"
mv "$TMP_KEY" "$DEST_KEY"
trap - EXIT

echo "[OK] deployed: $DEST_CERT (0644 root:root)"
echo "[OK] deployed: $DEST_KEY (0600 root:root)"

# --- Service management: OS-neutral. Detected once, not per service -
#     a host is either systemd or rcctl-based, not a mix. ---
if command -v rcctl >/dev/null 2>&1; then
	INIT_SYSTEM=rcctl
elif command -v systemctl >/dev/null 2>&1; then
	INIT_SYSTEM=systemctl
else
	INIT_SYSTEM=none
fi

restart_service() {
	case "$INIT_SYSTEM" in
		rcctl) rcctl restart "$1" ;;
		systemctl) systemctl restart "$1" ;;
		*) return 1 ;;
	esac
}

service_is_active() {
	case "$INIT_SYSTEM" in
		rcctl) rcctl check "$1" >/dev/null 2>&1 ;;
		systemctl) systemctl is-active --quiet "$1" ;;
		*) return 1 ;;
	esac
}

# --- Reload requested services ---
FAILED=no
if [[ ${#SERVICES[@]} -gt 0 && "$INIT_SYSTEM" == none ]]; then
	echo "[ERROR] no supported init system found (checked: rcctl, systemctl) - cannot restart services" >&2
	FAILED=yes
fi
for svc in "${SERVICES[@]}"; do
	[[ -z "$svc" ]] && continue
	[[ "$INIT_SYSTEM" == none ]] && continue
	if ! restart_service "$svc"; then
		echo "[ERROR] failed to restart service: $svc" >&2
		FAILED=yes
		continue
	fi
	if service_is_active "$svc"; then
		echo "[OK] service restarted: $svc"
	else
		echo "[ERROR] service not active after restart: $svc" >&2
		FAILED=yes
	fi
done

if [[ "$FAILED" == yes ]]; then
	exit 1
fi

echo ""
echo "-- lazy-admin-tools - dragons@work"
