#!/bin/bash
# lazy-admin-tools: Generate OpenSMTPD/Dovecot artifacts from /etc/mailserver
# Usage: mailserver-generate [--output DIR]
#
# Reads the declarative store and writes derived artifacts to DIR
# (default: /etc/mailserver/generated/ for standalone/manual use).
# mailserver-deploy calls this with --output pointing at a fresh
# generation directory under /etc/mailserver/generations/, so a
# staged generation is fully self-contained and can be validated in
# full before it is ever promoted to be the live "generated" target.
#
# Does NOT touch /etc/dovecot or /etc/smtpd.conf - that is
# mailserver-deploy's job, after mailserver-validate-generated has
# checked the staged outputs.
#
# Generated files are fully rewritten on every run - they are derived
# artifacts, not source of truth, so no merge/preserve logic applies.
#
# File-backed OpenSMTPD mapping tables use "key value" (whitespace or
# colon separated), not "key = value" - the "=" syntax is only for
# inline tables in smtpd.conf itself.
#
# Also generates smtpd-mailhosting.conf, an OpenSMTPD config fragment
# meant to be pulled into the host's own /etc/smtpd.conf via:
#   include "/etc/mailserver/generated/smtpd-mailhosting.conf"
# This tool never edits /etc/smtpd.conf itself - the include line must
# be added there once, by hand, alongside the host's own <aliases> and
# <localdomains> tables and its outbound relay action.
#
# IMPORTANT: the "table ... file:" lines inside smtpd-mailhosting.conf
# point at THIS RUN's own output directory ($OUT), not at the stable
# /etc/mailserver/generated path. This keeps a staged generation fully
# self-contained (fragment + its own tables), so validating the staged
# copy actually validates the new data, not whatever is still live at
# the stable path. mailserver-deploy promotes a whole generation to
# the stable path atomically (see that script) - at that point $OUT
# and the stable path are the same directory, so the table lines keep
# working unchanged after promotion.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
OUT="$BASE/generated"
STABLE_GENERATED_PATH="$BASE/generated"
# --- End configuration ---

if [[ "${1:-}" == "--output" ]]; then
	if [[ -z "${2:-}" ]]; then
		echo "Usage: mailserver-generate [--output DIR]" >&2
		exit 2
	fi
	OUT="$2"
elif [[ -n "${1:-}" ]]; then
	echo "Usage: mailserver-generate [--output DIR]" >&2
	exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

for f in domains domain-aliases mailboxes aliases secrets/users config; do
	if [[ ! -f "$BASE/$f" ]]; then
		echo "[ERROR] $BASE/$f not found - run mailserver-init first" >&2
		exit 1
	fi
done

strip_comments() {
	grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' || true
}

# Read a single "key = value" entry from /etc/mailserver/config.
# NOTE: must not gsub() into $1 in place - that rebuilds $0 with OFS
# and destroys the "=" separator before the later sub() can use it.
read_config() {
	local key="$1"
	awk -F'=' -v k="$key" '
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
	' "$BASE/config"
}

mkdir -p "$OUT"
chmod 700 "$OUT"

# --- dovecot users: direct passthrough of secrets/users ---
strip_comments "$BASE/secrets/users" > "$OUT/dovecot-users"
chmod 600 "$OUT/dovecot-users"
echo "[OK] generated dovecot-users ($(wc -l < "$OUT/dovecot-users") entries)"

# --- accepted domains: canonical + alias domains ---
{
	strip_comments "$BASE/domains"
	strip_comments "$BASE/domain-aliases" | awk '{print $1}'
} | sort -u > "$OUT/smtpd-domains"
echo "[OK] generated smtpd-domains ($(wc -l < "$OUT/smtpd-domains") entries)"

# --- classify aliases: local target vs external target ---
declare -A CANON_DOMAINS
while read -r d; do CANON_DOMAINS["$d"]=1; done < <(strip_comments "$BASE/domains")

is_mailbox() {
	grep -qxF "$1" "$BASE/mailboxes"
}

: > "$OUT/virtual-local"
: > "$OUT/virtual-forward"
: > "$OUT/smtpd-local-recipients"
: > "$OUT/smtpd-forward-recipients"

# Real mailboxes terminate expansion at the vmail system user.
while read -r addr; do
	echo "$addr vmail" >> "$OUT/virtual-local"
	echo "$addr" >> "$OUT/smtpd-local-recipients"
done < <(strip_comments "$BASE/mailboxes")

# Aliases: local target (points at a real mailbox) vs external target.
while read -r alias_addr target_addr; do
	target_domain="${target_addr#*@}"
	if [[ -n "${CANON_DOMAINS[$target_domain]:-}" ]] && is_mailbox "$target_addr"; then
		echo "$alias_addr $target_addr" >> "$OUT/virtual-local"
		echo "$alias_addr" >> "$OUT/smtpd-local-recipients"
	else
		echo "$alias_addr $target_addr" >> "$OUT/virtual-forward"
		echo "$alias_addr" >> "$OUT/smtpd-forward-recipients"
	fi
done < <(strip_comments "$BASE/aliases")

# --- domain aliases: explicit 1:1 expansion, no dynamic rewriting
#     (OpenSMTPD virtual tables do not support %{rcpt.user} substitution) ---
while read -r alias_domain canonical_domain; do
	# mirror every mailbox under the canonical domain
	while read -r mbox; do
		mbox_domain="${mbox#*@}"
		[[ "$mbox_domain" == "$canonical_domain" ]] || continue
		localpart="${mbox%@*}"
		mirrored="${localpart}@${alias_domain}"
		echo "$mirrored $mbox" >> "$OUT/virtual-local"
		echo "$mirrored" >> "$OUT/smtpd-local-recipients"
	done < <(strip_comments "$BASE/mailboxes")

	# mirror every alias under the canonical domain, preserving its
	# local/forward classification via the already-generated tables
	while read -r alias_addr target_addr; do
		alias_domain_part="${alias_addr#*@}"
		[[ "$alias_domain_part" == "$canonical_domain" ]] || continue
		localpart="${alias_addr%@*}"
		mirrored="${localpart}@${alias_domain}"
		target_domain="${target_addr#*@}"
		if [[ -n "${CANON_DOMAINS[$target_domain]:-}" ]] && is_mailbox "$target_addr"; then
			echo "$mirrored $target_addr" >> "$OUT/virtual-local"
			echo "$mirrored" >> "$OUT/smtpd-local-recipients"
		else
			echo "$mirrored $target_addr" >> "$OUT/virtual-forward"
			echo "$mirrored" >> "$OUT/smtpd-forward-recipients"
		fi
	done < <(strip_comments "$BASE/aliases")
done < <(strip_comments "$BASE/domain-aliases")

sort -u -o "$OUT/virtual-local" "$OUT/virtual-local"
sort -u -o "$OUT/virtual-forward" "$OUT/virtual-forward"
sort -u -o "$OUT/smtpd-local-recipients" "$OUT/smtpd-local-recipients"
sort -u -o "$OUT/smtpd-forward-recipients" "$OUT/smtpd-forward-recipients"

echo "[OK] generated virtual-local ($(wc -l < "$OUT/virtual-local") entries)"
echo "[OK] generated virtual-forward ($(wc -l < "$OUT/virtual-forward") entries)"
echo "[OK] generated smtpd-local-recipients ($(wc -l < "$OUT/smtpd-local-recipients") entries)"
echo "[OK] generated smtpd-forward-recipients ($(wc -l < "$OUT/smtpd-forward-recipients") entries)"

# --- smtpd-mailhosting.conf: self-contained fragment; table paths
#     point at $OUT (this run's own directory), not at the stable
#     path, so a staged generation validates its own new data. ---
DOVECOT_LMTP_SOCKET=$(read_config dovecot_lmtp_socket)

if [[ -z "$DOVECOT_LMTP_SOCKET" ]]; then
	echo "[ERROR] dovecot_lmtp_socket not set in $BASE/config" >&2
	exit 1
fi

cat > "$OUT/smtpd-mailhosting.conf" << EOF
# Generated by mailserver-generate - do not edit, changes will be lost.
# The host's own /etc/smtpd.conf should include the STABLE path once:
#   include "$STABLE_GENERATED_PATH/smtpd-mailhosting.conf"
# Requires <aliases> and <localdomains> tables to already be defined
# in the including file.

table smtpd_domains file:$OUT/smtpd-domains
table local_recipients file:$OUT/smtpd-local-recipients
table forward_recipients file:$OUT/smtpd-forward-recipients
table virtual_local file:$OUT/virtual-local
table virtual_forward file:$OUT/virtual-forward

action "system" forward-only alias <aliases>
action "dovecot" lmtp "$DOVECOT_LMTP_SOCKET" rcpt-to virtual <virtual_local>
action "forward" forward-only virtual <virtual_forward>

match for domain <localdomains> action "system"

# 'from any' is required here: a match rule without an explicit
# 'from' defaults to 'from local' (see smtpd.conf(5)), which would
# silently reject all externally submitted mail with
# "550 Invalid recipient". This is not an open relay - rcpt-to is
# still restricted to the known local_recipients/forward_recipients
# tables; only the source restriction is lifted.
match from any for rcpt-to <local_recipients> action "dovecot"
match from any for rcpt-to <forward_recipients> action "forward"
EOF
chmod 644 "$OUT/smtpd-mailhosting.conf"

echo "[OK] generated smtpd-mailhosting.conf"

echo "[OK] mailserver-generate complete - output in $OUT"
echo ""
echo "-- lazy-admin-tools - dragons@work"
