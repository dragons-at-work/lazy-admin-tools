#!/bin/bash
# lazy-admin-tools: Validate /etc/mailserver store consistency
# Usage: mailserver-validate
#
# Checks the declarative store for internal consistency - syntax,
# duplicates, cross-references between domains/mailboxes/aliases/
# credentials. Does not touch OpenSMTPD or Dovecot. Collects all
# errors before exiting, rather than failing on the first one.

set -uo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
KNOWN_CONFIG_KEYS="imap_hostname_pattern smtp_hostname_pattern mx_hostname_pattern dkim_selector vmail_base smtpd_conf_path dovecot_users_path dovecot_lmtp_socket"
# --- End configuration ---

DOMAIN_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
LOCALPART_RE='^[a-zA-Z0-9._%+-]+$'
HASH_RE='^\$6\$(rounds=[0-9]+\$)?[^$]+\$[^$]+$'

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

for f in domains domain-aliases mailboxes aliases defaults config domain-overrides secrets/users; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

ERRORS=0
err() {
	echo "[ERROR] $1" >&2
	ERRORS=$((ERRORS + 1))
}

strip_comments() {
	grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' || true
}

is_valid_domain() { [[ "$1" =~ $DOMAIN_RE ]]; }
is_valid_address() {
	local addr="$1"
	[[ "$addr" == *@* ]] || return 1
	local lp="${addr%@*}" dom="${addr#*@}"
	[[ "$lp" =~ $LOCALPART_RE ]] || return 1
	is_valid_domain "$dom" || return 1
	return 0
}

# --- Load raw data ---
mapfile -t DOMAINS < <(strip_comments "$BASE/domains")
mapfile -t DOMAIN_ALIASES < <(strip_comments "$BASE/domain-aliases")
mapfile -t MAILBOXES < <(strip_comments "$BASE/mailboxes")
mapfile -t ALIASES < <(strip_comments "$BASE/aliases")
mapfile -t CREDENTIALS < <(strip_comments "$BASE/secrets/users")

declare -A CANON_SET
declare -A ALIAS_DOMAIN_SET
declare -A MAILBOX_SET
declare -A ALIAS_ADDR_SET
declare -A CRED_SET

# --- domains ---
for d in "${DOMAINS[@]}"; do
	if ! is_valid_domain "$d"; then
		err "invalid domain syntax: $d"
		continue
	fi
	if [[ -n "${CANON_SET[$d]:-}" ]]; then
		err "duplicate canonical domain: $d"
	fi
	CANON_SET["$d"]=1
done
echo "[OK] domains: ${#DOMAINS[@]} entries"

# --- domain-aliases ---
for line in "${DOMAIN_ALIASES[@]}"; do
	field_count=$(awk '{print NF}' <<< "$line")
	if [[ "$field_count" -ne 2 ]]; then
		err "domain-aliases line has wrong field count (expected 2): $line"
		continue
	fi
	read -r alias_d canon_d <<< "$line"
	if ! is_valid_domain "$alias_d"; then
		err "invalid alias domain syntax: $alias_d"
		continue
	fi
	if ! is_valid_domain "$canon_d"; then
		err "invalid canonical domain syntax in domain-aliases: $canon_d"
		continue
	fi
	if [[ "$alias_d" == "$canon_d" ]]; then
		err "domain alias equals its canonical domain: $alias_d"
	fi
	if [[ -n "${CANON_SET[$alias_d]:-}" ]]; then
		err "domain is both canonical and an alias: $alias_d"
	fi
	if [[ -n "${ALIAS_DOMAIN_SET[$alias_d]:-}" ]]; then
		err "duplicate alias domain: $alias_d"
	fi
	if [[ -z "${CANON_SET[$canon_d]:-}" ]]; then
		err "domain-aliases references unknown canonical domain: $canon_d (for $alias_d)"
	fi
	ALIAS_DOMAIN_SET["$alias_d"]="$canon_d"
done
echo "[OK] domain-aliases: ${#DOMAIN_ALIASES[@]} entries"

# --- mailboxes ---
for addr in "${MAILBOXES[@]}"; do
	if ! is_valid_address "$addr"; then
		err "invalid mailbox address: $addr"
		continue
	fi
	local_dom="${addr#*@}"
	if [[ -z "${CANON_SET[$local_dom]:-}" ]]; then
		err "mailbox domain is not canonical: $addr"
	fi
	if [[ -n "${MAILBOX_SET[$addr]:-}" ]]; then
		err "duplicate mailbox: $addr"
	fi
	MAILBOX_SET["$addr"]=1
done
echo "[OK] mailboxes: ${#MAILBOXES[@]} entries"

# --- secrets/users ---
for line in "${CREDENTIALS[@]}"; do
	addr="${line%%:*}"
	hash="${line#*:}"
	if ! is_valid_address "$addr"; then
		err "invalid credential address: $addr"
		continue
	fi
	if ! [[ "$hash" =~ $HASH_RE ]]; then
		err "invalid credential hash for: $addr"
	fi
	if [[ -n "${CRED_SET[$addr]:-}" ]]; then
		err "duplicate credential: $addr"
	fi
	CRED_SET["$addr"]=1
	if [[ -z "${MAILBOX_SET[$addr]:-}" ]]; then
		err "credential has no mailbox: $addr"
	fi
done
for addr in "${!MAILBOX_SET[@]}"; do
	if [[ -z "${CRED_SET[$addr]:-}" ]]; then
		err "mailbox has no credential: $addr"
	fi
done
echo "[OK] credentials: ${#CREDENTIALS[@]} entries"

# --- aliases ---
for line in "${ALIASES[@]}"; do
	field_count=$(awk '{print NF}' <<< "$line")
	if [[ "$field_count" -ne 2 ]]; then
		err "aliases line has wrong field count (expected 2): $line"
		continue
	fi
	read -r alias_addr target_addr <<< "$line"
	if ! is_valid_address "$alias_addr"; then
		err "invalid alias address: $alias_addr"
		continue
	fi
	if ! is_valid_address "$target_addr"; then
		err "invalid alias target address: $target_addr (for $alias_addr)"
		continue
	fi
	alias_dom="${alias_addr#*@}"
	if [[ -z "${CANON_SET[$alias_dom]:-}" ]]; then
		err "alias domain is not canonical: $alias_addr"
	fi
	if [[ -n "${MAILBOX_SET[$alias_addr]:-}" ]]; then
		err "alias address is already a mailbox: $alias_addr"
	fi
	if [[ -n "${ALIAS_ADDR_SET[$alias_addr]:-}" ]]; then
		err "duplicate alias: $alias_addr"
	fi
	ALIAS_ADDR_SET["$alias_addr"]=1
	if [[ "$alias_addr" == "$target_addr" ]]; then
		err "self-referencing alias: $alias_addr"
	fi
	target_dom="${target_addr#*@}"
	if [[ -n "${CANON_SET[$target_dom]:-}" ]] && [[ -z "${MAILBOX_SET[$target_addr]:-}" ]]; then
		err "alias target is local but not an existing mailbox (chains not supported): $alias_addr -> $target_addr"
	fi
done
echo "[OK] aliases: ${#ALIASES[@]} entries"

# --- domain-overrides (mit Feldzahl-Prüfung + Duplikat-Check) ---
mapfile -t OVERRIDES < <(strip_comments "$BASE/domain-overrides")
declare -A OVERRIDE_SEEN
for line in "${OVERRIDES[@]}"; do
	field_count=$(awk '{print NF}' <<< "$line")
	if [[ "$field_count" -ne 3 ]]; then
		err "domain-overrides line has wrong field count (expected 3): $line"
		continue
	fi
	read -r dom key val <<< "$line"
	if [[ -z "${CANON_SET[$dom]:-}" ]]; then
		err "domain-overrides references unknown canonical domain: $dom"
	fi
	if [[ ! " $KNOWN_CONFIG_KEYS " =~ " $key " ]]; then
		err "domain-overrides uses unknown key: $key (for $dom)"
	fi
	if [[ -z "$val" ]]; then
		err "domain-overrides has empty value for $dom $key"
	fi
	override_key="${dom}|${key}"
	if [[ -n "${OVERRIDE_SEEN[$override_key]:-}" ]]; then
		err "duplicate domain override: $dom $key"
	fi
	OVERRIDE_SEEN["$override_key"]=1
done
echo "[OK] domain-overrides: ${#OVERRIDES[@]} entries"

# --- config ---
mapfile -t CONFIG_LINES < <(strip_comments "$BASE/config")
declare -A CONFIG_SEEN
for line in "${CONFIG_LINES[@]}"; do
	key=$(awk -F'=' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); print $1}' <<< "$line")
	val=$(awk -F'=' '{sub(/^[^=]*=/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' <<< "$line")
	if [[ ! " $KNOWN_CONFIG_KEYS " =~ " $key " ]]; then
		err "config has unknown key: $key"
		continue
	fi
	if [[ -n "${CONFIG_SEEN[$key]:-}" ]]; then
		err "config has duplicate key: $key"
	fi
	CONFIG_SEEN["$key"]=1
	if [[ -z "$val" ]]; then
		err "config key has empty value: $key"
	fi
done
for key in $KNOWN_CONFIG_KEYS; do
	if [[ -z "${CONFIG_SEEN[$key]:-}" ]]; then
		err "config is missing required key: $key"
	fi
done
echo "[OK] config: ${#CONFIG_LINES[@]} entries"

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
	echo "[OK] mailserver store is consistent"
else
	echo "[ERROR] mailserver store has $ERRORS problem(s)"
fi
echo ""
echo "-- lazy-admin-tools - dragons@work"

[[ "$ERRORS" -eq 0 ]]
