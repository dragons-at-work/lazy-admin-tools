#!/bin/bash
# lazy-admin-tools: Create a DKIM keypair for a domain
# Usage: mail-dkim-create <domain> [selector]
#        mail-dkim-create --force <domain> [selector]
#
# Generates a persistent DKIM key under /etc/mail/dkim/, group-owned by
# _rspamd (the rspamd system group) so the running rspamd daemon can
# read it, and prints the DNS TXT record to publish. The key is
# treated as long-lived state, like a certificate's private key -
# never regenerated automatically. Regenerating it without updating
# DNS would break signing (mismatch with the already-published public
# key), so this refuses to overwrite an existing key unless --force
# is given, and --force still does not touch DNS for you - update the
# TXT record yourself before or as part of the same change.
#
# Rspamd (sign-only, via opensmtpd-filter-rspamd) is the proven signer
# for multiple domains with independent keys. An earlier approach using
# opensmtpd-filter-dkimsign directly (one filter instance per domain,
# chained on the submission listener) was tested end-to-end with two
# real domains and rejected: OpenSMTPD runs every filter in a chain
# unconditionally, so every message got signed by every domain's
# filter regardless of its actual From: domain - each mail ended up
# with one correct signature and one spurious signature for an
# unrelated domain. Rspamd's dkim_signing module correctly selects the
# matching domain/key from the message's From: header, verified with a
# real message per domain showing exactly one correct signature each.
#
# selector defaults to the value of dkim_selector in config (global,
# or per-domain override via domain-overrides), following the same
# convention mailserver-generate already reads. If neither is set,
# selector must be given explicitly.
#
# This only creates the key and tells you what to publish - it does
# not touch DNS, does not install rspamd/opensmtpd-filter-rspamd, and
# does not wire up dkim_signing.conf's domain{} block. That remains a
# manual step for now (see docs/operations.md); mailserver-generate
# does not yet generate the rspamd DKIM fragment from the store.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
DKIM_DIR=/etc/mail/dkim
DKIM_GROUP=_rspamd
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

if ! getent group "$DKIM_GROUP" >/dev/null 2>&1; then
	echo "[ERROR] system group not found: $DKIM_GROUP (install rspamd first)" >&2
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

chown "root:$DKIM_GROUP" "$TMP_KEY"
chmod 640 "$TMP_KEY"
mv "$TMP_KEY" "$KEY_FILE"
trap - EXIT

PUBKEY_B64=$(openssl rsa -in "$KEY_FILE" -pubout 2>/dev/null | grep -v "PUBLIC KEY" | tr -d '\n')
if [[ -z "$PUBKEY_B64" ]]; then
	echo "[ERROR] key was written but public key extraction failed - check $KEY_FILE manually" >&2
	exit 1
fi

echo "[OK] DKIM key created: $KEY_FILE (root:$DKIM_GROUP, 0640)"
echo ""
echo "Publish this DNS TXT record:"
echo ""
echo "${SELECTOR}._domainkey.${DOMAIN}.  TXT  \"v=DKIM1; k=rsa; p=${PUBKEY_B64}\""
echo ""
echo "This tool does not publish DNS or wire up rspamd's dkim_signing"
echo "domain{} block for this key - that remains a manual step for now."
echo "See docs/operations.md."
echo ""
echo "-- lazy-admin-tools - dragons@work"
