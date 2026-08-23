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

# Read a config value for a specific domain, honoring domain-overrides
# before falling back to the global value from read_config. Same
# override mechanism already validated by mailserver-validate.
read_domain_config() {
	local domain="$1"
	local key="$2"
	local override
	override=$(awk -v d="$domain" -v k="$key" '$1==d && $2==k { print $3; exit }' "$BASE/domain-overrides")
	if [[ -n "$override" ]]; then
		echo "$override"
	else
		read_config "$key"
	fi
}

mkdir -p "$OUT"
chmod 700 "$OUT"

# --- dovecot users: direct passthrough of secrets/users ---
strip_comments "$BASE/secrets/users" > "$OUT/dovecot-users"
chmod 600 "$OUT/dovecot-users"
echo "[OK] generated dovecot-users ($(wc -l < "$OUT/dovecot-users") entries)"

# --- smtpd submission auth: same source of truth (secrets/users),
#     reshaped for OpenSMTPD's table(5) credentials format
#     ("user password", space-separated) instead of Dovecot's
#     passwd-file format ("user:password"). Generated independently
#     from dovecot-users rather than derived from it, so both trace
#     back to secrets/users directly rather than one generated
#     artifact depending on another. Mailbox credentials only for
#     now - relay/service credentials (e.g. for tiamat, typhon) are
#     a separate future source that a later version of this script
#     will merge in here, not mailbox users. ---
strip_comments "$BASE/secrets/users" \
	| awk -F: 'NF >= 2 { addr=$1; sub(/^[^:]*:/, "", $0); print addr, $0 }' \
	> "$OUT/smtpd-auth"
chmod 600 "$OUT/smtpd-auth"
echo "[OK] generated smtpd-auth ($(wc -l < "$OUT/smtpd-auth") entries)"

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

# --- smtpd-senders: which envelope-from addresses an authenticated
#     mailbox user is allowed to use on submission (port 587).
#     Policy: a mailbox may always send as itself, plus any local
#     address that virtual-local already resolves to it - a direct
#     alias, or a domain-alias mirror of either the mailbox or one of
#     its aliases. Nothing else. This is derived entirely from
#     virtual-local rather than a separate permission list, so there
#     is no second source of truth to keep in sync: virtual-local's
#     "K V" lines already encode exactly this relationship - "V ==
#     vmail" means K is a real mailbox (sender of itself), any other
#     V is the real mailbox that K (an alias or its domain-alias
#     mirror) ultimately resolves to. Addresses that only appear in
#     virtual-forward (external targets) never appear here, matching
#     the policy that forwards to external addresses must never be
#     usable as a local submission identity. ---
declare -A SENDERS_FOR
while read -r key value; do
	if [[ "$value" == vmail ]]; then
		SENDERS_FOR["$key"]="${SENDERS_FOR[$key]:+${SENDERS_FOR[$key]},}$key"
	else
		SENDERS_FOR["$value"]="${SENDERS_FOR[$value]:+${SENDERS_FOR[$value]},}$key"
	fi
done < "$OUT/virtual-local"

: > "$OUT/smtpd-senders"
for mailbox in "${!SENDERS_FOR[@]}"; do
	echo "$mailbox ${SENDERS_FOR[$mailbox]}" >> "$OUT/smtpd-senders"
done
sort -o "$OUT/smtpd-senders" "$OUT/smtpd-senders"
chmod 644 "$OUT/smtpd-senders"

echo "[OK] generated smtpd-senders ($(wc -l < "$OUT/smtpd-senders") entries)"

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

# --- smtpd-mailtls.conf: pki blocks + SNI-multiplexed listeners for
#     ports 25 and 587, one fragment covering every canonical domain.
#     Fail-closed: every active domain must already have a matching,
#     name-complete certificate deployed under /etc/ssl/local/ before
#     this fragment is generated - no domain silently ends up without
#     TLS because its certificate was missing or stale. Certificates
#     themselves are managed by the separate cert/ toolset (cert-add,
#     cert-deploy); this only reads what has already been deployed
#     there and refuses to proceed if it is not what mail expects. ---
TLS_CERT_ROOT=/etc/ssl/local

if ! command -v openssl >/dev/null 2>&1; then
	echo "[ERROR] openssl not found - required to verify mail TLS certificates" >&2
	exit 1
fi

PKI_BLOCKS=""
PKI_NAMES=()

while read -r domain; do
	MX_HOST=$(read_domain_config "$domain" mx_hostname_pattern | sed "s/%domain%/$domain/")
	SMTP_HOST=$(read_domain_config "$domain" smtp_hostname_pattern | sed "s/%domain%/$domain/")
	IMAP_HOST=$(read_domain_config "$domain" imap_hostname_pattern | sed "s/%domain%/$domain/")

	if [[ -z "$MX_HOST" || -z "$SMTP_HOST" || -z "$IMAP_HOST" ]]; then
		echo "[ERROR] $domain: mx_hostname_pattern, smtp_hostname_pattern, and imap_hostname_pattern must all be set" >&2
		exit 1
	fi

	CERT="$TLS_CERT_ROOT/$MX_HOST/cert.pem"
	KEY="$TLS_CERT_ROOT/$MX_HOST/key.pem"

	if [[ ! -f "$CERT" ]]; then
		echo "[ERROR] $domain: certificate not found: $CERT - run cert-add and cert-deploy for $MX_HOST first" >&2
		exit 1
	fi
	if [[ ! -f "$KEY" ]]; then
		echo "[ERROR] $domain: key not found: $KEY - run cert-add and cert-deploy for $MX_HOST first" >&2
		exit 1
	fi

	# Certificate and key must actually belong together - same public
	# key comparison used by cert-deploy, checked again here since
	# mail generation must not trust a deployed pair blindly.
	CERT_PUBKEY="$(openssl x509 -in "$CERT" -noout -pubkey 2>/dev/null || true)"
	KEY_PUBKEY="$(openssl pkey -in "$KEY" -pubout 2>/dev/null || true)"
	if [[ -z "$CERT_PUBKEY" || -z "$KEY_PUBKEY" || "$CERT_PUBKEY" != "$KEY_PUBKEY" ]]; then
		echo "[ERROR] $domain: certificate and key at $TLS_CERT_ROOT/$MX_HOST do not match" >&2
		exit 1
	fi

	# Certificate must cover all three conventional hostnames, not
	# just the MX name it is filed under - mail-domain-create always
	# requests mx/smtp/imap together (see cert-add usage), so a
	# certificate missing any of them is stale or was issued wrong.
	CERT_SANS=" $(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^,]*' | sed 's/DNS://g' | tr '\n' ' ') "
	for required_host in "$MX_HOST" "$SMTP_HOST" "$IMAP_HOST"; do
		if [[ "$CERT_SANS" != *" $required_host "* ]]; then
			echo "[ERROR] $domain: certificate at $CERT does not cover $required_host - reissue with cert-add $MX_HOST $SMTP_HOST $IMAP_HOST" >&2
			exit 1
		fi
	done

	PKI_BLOCKS="$PKI_BLOCKS
pki $MX_HOST cert \"$CERT\"
pki $MX_HOST key \"$KEY\""
	PKI_NAMES+=("$MX_HOST")

	echo "[OK] $domain: certificate verified ($MX_HOST, covers $SMTP_HOST + $IMAP_HOST)"
done < <(strip_comments "$BASE/domains")

if [[ ${#PKI_NAMES[@]} -eq 0 ]]; then
	echo "[ERROR] no canonical domains configured - nothing to generate TLS listeners for" >&2
	exit 1
fi

PKI_REFS=""
for name in "${PKI_NAMES[@]}"; do
	PKI_REFS="$PKI_REFS pki $name"
done

# --- DKIM (rspamd sign-only): opt-in via the global "dkim_backend"
#     config key. Only "rspamd" is supported - the proven path after
#     a chained opensmtpd-filter-dkimsign setup was tested end-to-end
#     with two real domains and rejected (every filter in an OpenSMTPD
#     chain runs unconditionally, so every domain's filter signed
#     every message regardless of its actual From: domain). See
#     docs/operations.md for the full comparison.
#
#     Fail-closed like the TLS block above: every canonical domain
#     must already have a matching, readable DKIM key at the location
#     mail-dkim-create would have put it, before this fragment is
#     generated - no domain silently ends up unsigned because its key
#     was missing, unreadable, or not actually a private key. DKIM
#     keys themselves are managed separately (mail-dkim-create); this
#     only reads what has already been created and refuses to proceed
#     if it is not what mail expects. ---
DKIM_BACKEND=$(read_config dkim_backend)
DKIM_ROOT=/etc/mail/dkim
DKIM_FILTER_DECL=""
DKIM_FILTER_REF=""

case "$DKIM_BACKEND" in
	""|none)
		{
			echo "# Generated by mailserver-generate - do not edit, changes will be lost."
			echo "# DKIM signing is disabled (dkim_backend is unset or \"none\" in config)."
			echo "# See docs/operations.md for how to enable it."
		} > "$OUT/rspamd-dkim_signing.conf"
		chmod 644 "$OUT/rspamd-dkim_signing.conf"
		echo "[OK] generated rspamd-dkim_signing.conf (disabled)"
		;;
	rspamd)
		if ! command -v openssl >/dev/null 2>&1; then
			echo "[ERROR] openssl not found - required to verify DKIM keys" >&2
			exit 1
		fi

		DKIM_DOMAIN_BLOCKS=""
		DKIM_DOMAIN_COUNT=0

		while read -r domain; do
			DKIM_SELECTOR=$(read_domain_config "$domain" dkim_selector)
			if [[ -z "$DKIM_SELECTOR" ]]; then
				echo "[ERROR] $domain: dkim_selector not set (config or domain-overrides) - required when dkim_backend = rspamd" >&2
				exit 1
			fi

			DKIM_KEY="$DKIM_ROOT/$domain.$DKIM_SELECTOR.key"

			if [[ ! -f "$DKIM_KEY" ]]; then
				echo "[ERROR] $domain: DKIM key not found: $DKIM_KEY - run mail-dkim-create $domain first" >&2
				exit 1
			fi
			# Check readability AND validity as the actual consumer
			# (_rspamd), not as root - this script runs as root, so a
			# plain "[[ -r ]]" check only proves root can read it, not
			# that the rspamd process can. Runs openssl as _rspamd via
			# runuser, which fails closed if the group doesn't exist or
			# the key isn't readable to it.
			if ! getent passwd _rspamd >/dev/null 2>&1; then
				echo "[ERROR] $domain: system user _rspamd not found - install rspamd first" >&2
				exit 1
			fi
			if ! runuser -u _rspamd -- openssl pkey -in "$DKIM_KEY" -noout >/dev/null 2>&1; then
				echo "[ERROR] $domain: $DKIM_KEY is not readable by _rspamd, or is not a valid private key" >&2
				exit 1
			fi

			DKIM_DOMAIN_BLOCKS="$DKIM_DOMAIN_BLOCKS
    $domain {
        selector = \"$DKIM_SELECTOR\";
        path = \"$DKIM_KEY\";
    }"
			DKIM_DOMAIN_COUNT=$((DKIM_DOMAIN_COUNT + 1))

			echo "[OK] $domain: DKIM key verified ($DKIM_KEY, selector $DKIM_SELECTOR)"
		done < <(strip_comments "$BASE/domains")

		if [[ "$DKIM_DOMAIN_COUNT" -eq 0 ]]; then
			echo "[ERROR] no canonical domains configured - nothing to generate DKIM signing for" >&2
			exit 1
		fi

		{
			echo "# Generated by mailserver-generate - do not edit, changes will be lost."
			echo "# mailserver-deploy installs this to rspamd's local.d/dkim_signing.conf"
			echo "# automatically when dkim_backend = rspamd (backed up and rolled back"
			echo "# the same way as dovecot-users). This file is not consumed directly"
			echo "# from here - rspamd's own config directory is outside this store."
			echo ""
			echo "use_domain = \"header\";"
			echo "use_redis = false;"
			echo "sign_authenticated = true;"
			echo "sign_local = true;"
			echo ""
			echo "domain {$DKIM_DOMAIN_BLOCKS"
			echo "}"
		} > "$OUT/rspamd-dkim_signing.conf"
		chmod 644 "$OUT/rspamd-dkim_signing.conf"
		echo "[OK] generated rspamd-dkim_signing.conf ($DKIM_DOMAIN_COUNT domain(s))"

		DKIM_FILTER_DECL='filter "rspamd_outgoing" proc-exec "filter-rspamd -settings-id outgoing"
'
		DKIM_FILTER_REF=' filter "rspamd_outgoing"'
		;;
	*)
		echo "[ERROR] unknown dkim_backend: $DKIM_BACKEND (supported: rspamd, none)" >&2
		exit 1
		;;
esac

{
	echo "# Generated by mailserver-generate - do not edit, changes will be lost."
	echo "# The host's own /etc/smtpd.conf should include the STABLE path once:"
	echo "#   include \"$STABLE_GENERATED_PATH/smtpd-mailtls.conf\""
	echo "# Requires <submission_auth> to not already be defined elsewhere in"
	echo "# the including file."
	echo ""
	echo "table submission_auth file:$OUT/smtpd-auth"
	echo "table submission_senders file:$OUT/smtpd-senders"
	echo "$PKI_BLOCKS"
	echo ""
	if [[ -n "$DKIM_FILTER_DECL" ]]; then
		echo "$DKIM_FILTER_DECL"
	fi
	echo "listen on 0.0.0.0 port 25 tls$PKI_REFS"
	echo "listen on ::    port 25 tls$PKI_REFS"
	echo "listen on 0.0.0.0 port 587 tls-require auth <submission_auth> senders <submission_senders>$PKI_REFS$DKIM_FILTER_REF"
	echo "listen on ::    port 587 tls-require auth <submission_auth> senders <submission_senders>$PKI_REFS$DKIM_FILTER_REF"
} > "$OUT/smtpd-mailtls.conf"
chmod 644 "$OUT/smtpd-mailtls.conf"

echo "[OK] generated smtpd-mailtls.conf (${#PKI_NAMES[@]} domain(s), dkim_backend=$([ -z "$DKIM_BACKEND" ] && echo none || echo "$DKIM_BACKEND"))"

echo "[OK] mailserver-generate complete - output in $OUT"
echo ""
echo "-- lazy-admin-tools - dragons@work"
