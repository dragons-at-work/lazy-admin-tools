#!/bin/bash
# lazy-admin-tools: Remove a canonical mail domain
# Usage: mail-domain-del [--force] <domain>
#
# Refuses to remove a domain that still has mailboxes, aliases, or
# alias domains pointing at it - removing it first would silently
# orphan all of those. Use --force to remove anyway; the dependent
# mailboxes/aliases/domain-aliases are NOT removed automatically (that
# would be too destructive for a single command) - mailserver-validate
# will report the resulting inconsistencies so they can be cleaned up
# deliberately with mail-mailbox-del / mail-alias-del /
# mail-domain-alias-del.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

FORCE=no
if [[ "${1:-}" == "--force" ]]; then
	FORCE=yes
	shift
fi

if [[ $# -ne 1 ]]; then
	echo "Usage: mail-domain-del [--force] <domain>" >&2
	exit 2
fi

DOMAIN="$1"

for f in domains domain-aliases mailboxes aliases; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

if ! grep -qxF "$DOMAIN" "$BASE/domains"; then
	echo "[ERROR] domain does not exist: $DOMAIN" >&2
	exit 1
fi

DEPENDENT_MAILBOXES=$(awk -F'@' -v d="$DOMAIN" '$2==d' "$BASE/mailboxes")
DEPENDENT_ALIASES=$(awk -F'@' -v d="$DOMAIN" '{split($0,f," "); split(f[1],a,"@"); if (a[2]==d) print $0}' "$BASE/aliases")
DEPENDENT_DOMAIN_ALIASES=$(awk -v d="$DOMAIN" '$2==d {print $1}' "$BASE/domain-aliases")

HAS_DEPENDENTS=no
if [[ -n "$DEPENDENT_MAILBOXES" || -n "$DEPENDENT_ALIASES" || -n "$DEPENDENT_DOMAIN_ALIASES" ]]; then
	HAS_DEPENDENTS=yes
fi

if [[ "$HAS_DEPENDENTS" == "yes" && "$FORCE" != "yes" ]]; then
	echo "[ERROR] domain still has dependents:" >&2
	[[ -n "$DEPENDENT_MAILBOXES" ]] && while read -r m; do echo "[ERROR]   mailbox: $m" >&2; done <<< "$DEPENDENT_MAILBOXES"
	[[ -n "$DEPENDENT_ALIASES" ]] && while read -r a; do echo "[ERROR]   alias: $a" >&2; done <<< "$DEPENDENT_ALIASES"
	[[ -n "$DEPENDENT_DOMAIN_ALIASES" ]] && while read -r ad; do echo "[ERROR]   alias domain: $ad -> $DOMAIN" >&2; done <<< "$DEPENDENT_DOMAIN_ALIASES"
	echo "[ERROR] remove those first, or re-run with --force (dependents are left in place, not cleaned up)" >&2
	exit 1
fi
if [[ "$HAS_DEPENDENTS" == "yes" ]]; then
	echo "[WARN] removing domain with dependents still referencing it (--force) - they are NOT removed:"
	[[ -n "$DEPENDENT_MAILBOXES" ]] && while read -r m; do echo "[WARN]   mailbox: $m"; done <<< "$DEPENDENT_MAILBOXES"
	[[ -n "$DEPENDENT_ALIASES" ]] && while read -r a; do echo "[WARN]   alias: $a"; done <<< "$DEPENDENT_ALIASES"
	[[ -n "$DEPENDENT_DOMAIN_ALIASES" ]] && while read -r ad; do echo "[WARN]   alias domain: $ad -> $DOMAIN"; done <<< "$DEPENDENT_DOMAIN_ALIASES"
fi

ORIG_MODE=$(stat -c '%a' "$BASE/domains")
ORIG_OWNER=$(stat -c '%U:%G' "$BASE/domains")

TMP=$(mktemp "$BASE/.domains.XXXXXX")
grep -vxF "$DOMAIN" "$BASE/domains" > "$TMP" || true
chmod "$ORIG_MODE" "$TMP"
chown "$ORIG_OWNER" "$TMP"
mv "$TMP" "$BASE/domains"

echo "[OK] domain removed: $DOMAIN"
echo ""
echo "-- lazy-admin-tools - dragons@work"
