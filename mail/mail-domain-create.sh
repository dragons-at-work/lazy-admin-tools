#!/bin/bash
# lazy-admin-tools: Provision a canonical mail domain (orchestrator)
# Usage: mail-domain-create [--hash '<existing-hash>'] <domain> [admin-target]
#
# Composes the CRUD primitives (mail-domain-add, mail-mailbox-add,
# mail-alias-add) into one provisioning step - it does not write
# domains, mailboxes, secrets/users or aliases itself.
#
# admin-target contract:
#   (omitted)                  -> info@<domain>, new mailbox
#   info                       -> info@<domain>, new mailbox
#   info@<domain>              -> new mailbox on this same domain
#   michael@dragons-at-work.de -> no new mailbox here, roles alias to
#                                  this existing/external address
#
# A bare word with no "@" is always treated as a localpart on <domain>
# and always creates a mailbox there. A full address (contains "@") is
# used as-is as the alias target; a mailbox is only created for it if
# its domain equals <domain> AND it does not already exist.
#
# Every non-comment role in defaults (postmaster, abuse, webmaster,
# hostmaster, ...) is added as an alias pointing at admin-target. If
# any step fails, everything already created in this run is rolled
# back (in reverse order).

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
# --- End configuration ---

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
LOCALPART_RE='^[a-zA-Z0-9._%+-]+$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

HASH_ARGS=()
if [[ "${1:-}" == "--hash" ]]; then
	if [[ $# -lt 3 ]]; then
		echo "Usage: mail-domain-create [--hash '<existing-hash>'] <domain> [admin-target]" >&2
		exit 2
	fi
	HASH_ARGS=(--hash "$2")
	shift 2
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "Usage: mail-domain-create [--hash '<existing-hash>'] <domain> [admin-target]" >&2
	exit 2
fi

DOMAIN="$1"
ADMIN_TARGET="${2:-info}"

for f in domains domain-aliases mailboxes aliases defaults; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

# --- Validate everything up front, before touching any file ---

if ! [[ "$DOMAIN" =~ $DOMAIN_RE ]]; then
	echo "[ERROR] not a valid domain: $DOMAIN" >&2
	exit 1
fi

# Resolve admin-target into a full address and whether it needs a
# fresh mailbox on THIS domain.
if [[ "$ADMIN_TARGET" == *@* ]]; then
	ADMIN_ADDRESS="$ADMIN_TARGET"
	ADMIN_LOCALPART="${ADMIN_ADDRESS%@*}"
	ADMIN_DOMAIN="${ADMIN_ADDRESS#*@}"
	if ! [[ "$ADMIN_LOCALPART" =~ $LOCALPART_RE ]]; then
		echo "[ERROR] not a valid admin-target local part: $ADMIN_LOCALPART" >&2
		exit 1
	fi
	if ! [[ "$ADMIN_DOMAIN" =~ $DOMAIN_RE ]]; then
		echo "[ERROR] not a valid admin-target domain: $ADMIN_DOMAIN" >&2
		exit 1
	fi
	if [[ "$ADMIN_DOMAIN" == "$DOMAIN" ]]; then
		NEEDS_MAILBOX=yes
	else
		NEEDS_MAILBOX=no
		if [[ -n "${HASH_ARGS[*]:-}" ]]; then
			echo "[ERROR] --hash given but admin-target is not on $DOMAIN - nothing to create a mailbox for" >&2
			exit 1
		fi
	fi
else
	if ! [[ "$ADMIN_TARGET" =~ $LOCALPART_RE ]]; then
		echo "[ERROR] not a valid admin-target local part: $ADMIN_TARGET" >&2
		exit 1
	fi
	ADMIN_LOCALPART="$ADMIN_TARGET"
	ADMIN_ADDRESS="${ADMIN_LOCALPART}@${DOMAIN}"
	NEEDS_MAILBOX=yes
fi

if grep -qxF "$DOMAIN" "$BASE/domains"; then
	echo "[ERROR] domain already exists: $DOMAIN" >&2
	exit 1
fi

if awk -v d="$DOMAIN" '$1==d' "$BASE/domain-aliases" | grep -q .; then
	echo "[ERROR] domain is already configured as an alias: $DOMAIN" >&2
	exit 1
fi

if [[ "$NEEDS_MAILBOX" == yes ]]; then
	if grep -qxF "$ADMIN_ADDRESS" "$BASE/mailboxes"; then
		echo "[ERROR] admin mailbox already exists: $ADMIN_ADDRESS" >&2
		exit 1
	fi
	if awk -v a="$ADMIN_ADDRESS" '$1==a' "$BASE/aliases" | grep -q .; then
		echo "[ERROR] admin address is already an alias: $ADMIN_ADDRESS" >&2
		exit 1
	fi
fi

# Collect roles from defaults, skipping blank lines and comments, and
# reject duplicates now - a duplicate is a config error we can detect
# before changing anything, not a runtime failure to roll back from.
ROLES=()
declare -A SEEN_ROLES=()
while IFS= read -r role || [[ -n "$role" ]]; do
	[[ -z "$role" || "$role" == \#* ]] && continue
	if [[ -n "${SEEN_ROLES[$role]:-}" ]]; then
		echo "[ERROR] duplicate role in defaults: $role" >&2
		exit 1
	fi
	SEEN_ROLES[$role]=1
	ROLES+=("$role")
done < "$BASE/defaults"

if [[ ${#ROLES[@]} -eq 0 ]]; then
	echo "[ERROR] no roles defined in $BASE/defaults" >&2
	exit 1
fi

for role in "${ROLES[@]}"; do
	if ! [[ "$role" =~ $LOCALPART_RE ]]; then
		echo "[ERROR] not a valid role local part in defaults: $role" >&2
		exit 1
	fi
	ROLE_ADDRESS="${role}@${DOMAIN}"
	if [[ "$ROLE_ADDRESS" == "$ADMIN_ADDRESS" ]]; then
		echo "[ERROR] role collides with admin-target address: $ROLE_ADDRESS" >&2
		exit 1
	fi
done

# --- Rollback bookkeeping ---
CREATED_ALIASES=()
MAILBOX_CREATED=no
DOMAIN_CREATED=no

rollback() {
	echo "[WARN] rolling back mail-domain-create for $DOMAIN" >&2
	for ((i=${#CREATED_ALIASES[@]}-1; i>=0; i--)); do
		"$SCRIPT_DIR/mail-alias-del.sh" "${CREATED_ALIASES[$i]}" >&2 || true
	done
	if [[ "$MAILBOX_CREATED" == yes ]]; then
		"$SCRIPT_DIR/mail-mailbox-del.sh" "$ADMIN_ADDRESS" >&2 || true
	fi
	if [[ "$DOMAIN_CREATED" == yes ]]; then
		if ! "$SCRIPT_DIR/mail-domain-del.sh" --force "$DOMAIN" >&2; then
			echo "[ERROR] rollback could not remove domain: $DOMAIN - manual cleanup required" >&2
		fi
	fi
}

# --- Execute: primitive mail-domain-add, then optional admin mailbox,
#     then role aliases ---

if ! "$SCRIPT_DIR/mail-domain-add.sh" "$DOMAIN"; then
	echo "[ERROR] failed to add domain: $DOMAIN" >&2
	exit 1
fi
DOMAIN_CREATED=yes

if [[ "$NEEDS_MAILBOX" == yes ]]; then
	if ! "$SCRIPT_DIR/mail-mailbox-add.sh" "${HASH_ARGS[@]}" "$ADMIN_ADDRESS"; then
		echo "[ERROR] failed to add admin mailbox: $ADMIN_ADDRESS" >&2
		rollback
		exit 1
	fi
	MAILBOX_CREATED=yes
else
	echo "[OK] using existing/external admin-target, no mailbox created: $ADMIN_ADDRESS"
fi

for role in "${ROLES[@]}"; do
	ROLE_ADDRESS="${role}@${DOMAIN}"
	if ! "$SCRIPT_DIR/mail-alias-add.sh" "$ROLE_ADDRESS" "$ADMIN_ADDRESS"; then
		echo "[ERROR] failed to add role alias: $ROLE_ADDRESS -> $ADMIN_ADDRESS" >&2
		rollback
		exit 1
	fi
	CREATED_ALIASES+=("$ROLE_ADDRESS")
done

echo "[OK] mail-domain-create complete: $DOMAIN (admin-target: $ADMIN_ADDRESS, roles: ${ROLES[*]})"
echo ""
echo "-- lazy-admin-tools - dragons@work"
