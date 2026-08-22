#!/bin/bash
# lazy-admin-tools: cert-del - remove a certificate's local state
# Usage: cert-del [--backend uacme] [--force] <primary-name>
#
# Deliberately narrow scope:
#   - removes the ACME backend's local state for this certificate
#   - removes the deployed copy under /etc/ssl/local/<primary-name>/
#   - removes the optional service-reload manifest
#     /etc/cert-deploy/<primary-name>.services
#
# Does NOT:
#   - revoke the certificate at the CA (a separate, more destructive
#     operation for cases like a compromised key - not implemented
#     here; local removal and cryptographic revocation are different
#     things with different triggers)
#   - touch any service configuration (mail, web, etc.) that might
#     reference this certificate
#
# Consumer protection: if a service-reload manifest exists for this
# primary, that is this toolset's own signal that some service on
# this host was wired to reload on renewal - refuses to delete unless
# --force is given. This is deliberately generic (cert/ knows nothing
# about what mail-domain-create or any other tool considers a
# "domain in use") - the manifest is cert/'s own record of a known
# consumer, not a dependency on another toolset's store.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backends"

# --- Configuration ---
DEST_ROOT=/etc/ssl/local
SERVICES_MANIFEST_DIR=/etc/cert-deploy
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

BACKEND=""
FORCE=no

while [[ $# -gt 0 ]]; do
	case "$1" in
		--backend)
			if [[ $# -lt 2 || -z "${2:-}" ]]; then
				echo "Usage: cert-del [--backend uacme] [--force] <primary-name>" >&2
				exit 2
			fi
			BACKEND="$2"
			shift 2
			;;
		--force)
			FORCE=yes
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			echo "Usage: cert-del [--backend uacme] [--force] <primary-name>" >&2
			exit 2
			;;
		*)
			break
			;;
	esac
done

if [[ $# -ne 1 ]]; then
	echo "Usage: cert-del [--backend uacme] [--force] <primary-name>" >&2
	exit 2
fi

PRIMARY="$1"

# --- Backend selection: same auto-detect logic as cert-add/cert-deploy ---
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

# --- Consumer protection ---
MANIFEST="$SERVICES_MANIFEST_DIR/$PRIMARY.services"
if [[ -f "$MANIFEST" && "$FORCE" != yes ]]; then
	echo "[ERROR] $MANIFEST exists - this certificate has a known service consumer on this host" >&2
	echo "[ERROR] refusing to delete without --force" >&2
	echo "[ERROR] remove the manifest yourself first if the consumer is really gone, or pass --force" >&2
	exit 1
fi

# --- Remove backend state ---
if ! "$BACKEND_SCRIPT" del "$PRIMARY"; then
	echo "[ERROR] backend failed to remove state for $PRIMARY" >&2
	exit 1
fi

# --- Remove deployed copy, if any ---
DEST_DIR="$DEST_ROOT/$PRIMARY"
if [[ -d "$DEST_DIR" ]]; then
	rm -rf "$DEST_DIR"
	echo "[OK] removed deployed copy: $DEST_DIR"
else
	echo "[INFO] no deployed copy found: $DEST_DIR"
fi

# --- Remove the manifest itself, now that deletion has proceeded
#     (whether it was absent to begin with, or removed via --force) -
#     a manifest pointing at a now-deleted certificate would only be
#     stale and misleading for a future cert-renew run. ---
if [[ -f "$MANIFEST" ]]; then
	rm -f "$MANIFEST"
	echo "[OK] removed service manifest: $MANIFEST"
fi

echo "[OK] cert-del complete: $PRIMARY"
echo ""
echo "-- lazy-admin-tools - dragons@work"
