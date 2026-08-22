#!/bin/bash
# lazy-admin-tools: Create a DKIM keypair for a domain
# Usage: mail-dkim-create <domain> [selector]
#        mail-dkim-create --force <domain> [selector]
#
# Generates a persistent DKIM key under /etc/mail/dkim/, owned by the
# opensmtpd-filter-dkimsign system user (_dkimsign), and prints the
# DNS TXT record to publish. The key is treated as long-lived state,
# like a certificate's private key - never regenerated automatically.
# Regenerating it without updating DNS would break signing (mismatch
# with the already-published public key), so this refuses to
# overwrite an existing key unless --force is given, and --force still
# does not touch DNS for you - update the TXT record yourself before
# or as part of the same change.
#
# selector defaults to the value of dkim_selector in config (global,
# or per-domain override via domain-overrides), following the same
# convention mailserver-generate already reads. If neither is set,
# selector must be given explicitly.
#
# This only creates the key and tells you what to publish - it does
# not touch smtpd.conf, does not install opensmtpd-filter-dkimsign,
# and does not wire up the filter. That wiring is currently a manual,
# proven-by-hand step (see docs/operations.md) - mailserver-generate
# does not yet generate the DKIM filter fragment for multiple domains,
# since opensmtpd-filter-dkimsign's behavior with more than one
# domain/key/selector chained on one listener has not been verified
# end-to-end yet (only a single domain has been proven in production).

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
DKIM_DIR=/etc/mail/dkim
DKIM_USER=_dkimsign
KEY_BITS=2048
# --- End configuration ---

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
SELECTOR_RE_BASH='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

FORCE=no
if [[ "${1:-}" == "--force" ]]; then
	FORCE=yes
	shift
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "Usage: mail-dkim-create [--force] <domain> [selector]" >&2
	exit 2
fi

DOMAIN="$1"
SELECTOR="${2:-}"

if ! [[ "$DOMAIN" =~ $DOMAIN_RE ]]; then
	echo "[ERROR] not a valid domain: $DOMAIN" >&2
	exit 1
fi

# --- Resolve selector: explicit argument, else domain-overrides,
#     else global config. Same precedence as mailserver-generate's
#     read_domain_config, kept here independently since this tool
#     must also work before mailserver-init has ever run a generation
#     (e.g. right after mailserver-init). ---
if [[ -z "$SELECTOR" ]]; then
	if [[ -f "$BASE/domain-overrides" ]]; then
		SELECTOR=$(awk -v d="$DOMAIN" -v k="dkim_selector" '$1==d && $2==k { print $3; exit }' "$BASE/domain-overrides")
	fi
fi
if [[ -z "$SELECTOR" && -f "$BASE/config" ]]; then
	SELECTOR=$(awk -F'=' -v k="dkim_selector" '
		{
			trimmed_key = $1
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed_key)
		}
		trimmed_key == k {
			val = $0
			sub(/^[^=]*=/, "", val)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			print val
			exit
		}
	' "$BASE/config")
fi

if [[ -z "$SELECTOR" ]]; then
	echo "[ERROR] no selector given and no dkim_selector found in config or domain-overrides for $DOMAIN" >&2
	exit 1
fi

if ! [[ "$SELECTOR" =~ $SELECTOR_RE_BASH ]]; then
	echo "[ERROR] not a valid selector: $SELECTOR" >&2
	exit 1
fi

if ! id "$DKIM_USER" >/dev/null 2>&1; then
	echo "[ERROR] system user not found: $DKIM_USER (install opensmtpd-filter-dkimsign first)" >&2
	exit 1
fi

KEY_FILE="$DKIM_DIR/$DOMAIN.$SELECTOR.key"

if [[ -f "$KEY_FILE" && "$FORCE" != yes ]]; then
	echo "[ERROR] key already exists: $KEY_FILE" >&2
	echo "[ERROR] refusing to overwrite without --force - a new key invalidates the already-published DNS record" >&2
	exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
	echo "[ERROR] openssl not found" >&2
	exit 1
fi

mkdir -p "$DKIM_DIR"
chmod 755 "$DKIM_DIR"

TMP_KEY=$(mktemp "$DKIM_DIR/.dkim.XXXXXX")
cleanup() { rm -f "$TMP_KEY"; }
trap cleanup EXIT

if ! openssl genrsa -out "$TMP_KEY" "$KEY_BITS" >/dev/null 2>&1; then
	echo "[ERROR] failed to generate key" >&2
	exit 1
fi

chown "$DKIM_USER:$DKIM_USER" "$TMP_KEY"
chmod 600 "$TMP_KEY"
mv "$TMP_KEY" "$KEY_FILE"
trap - EXIT

PUBKEY_B64=$(openssl rsa -in "$KEY_FILE" -pubout 2>/dev/null | grep -v "PUBLIC KEY" | tr -d '\n')
if [[ -z "$PUBKEY_B64" ]]; then
	echo "[ERROR] key was written but public key extraction failed - check $KEY_FILE manually" >&2
	exit 1
fi

echo "[OK] DKIM key created: $KEY_FILE ($DKIM_USER:$DKIM_USER, 0600)"
echo ""
echo "Publish this DNS TXT record:"
echo ""
echo "${SELECTOR}._domainkey.${DOMAIN}.  TXT  \"v=DKIM1; k=rsa; p=${PUBKEY_B64}\""
echo ""
echo "This tool does not publish DNS or wire up the OpenSMTPD filter -"
echo "both remain manual steps until the multi-domain filter behavior"
echo "has been verified end-to-end. See docs/operations.md."
echo ""
echo "-- lazy-admin-tools - dragons@work"
