# lazy-admin-tools: mailserver-generate - store-derived artifacts
# Sourced by mailserver-generate.sh after common.sh. Relies on $BASE
# and $OUT already being set, and strip_comments() already defined.
# Not standalone executable.

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
