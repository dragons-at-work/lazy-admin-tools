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
# All targets for the same alias address are aggregated first, then
# written as ONE line per alias with a comma-separated value list -
# OpenSMTPD's table(5) aliasing format documents multiple recipients
# as "one or many recipients" in the value of a single key line, not
# as repeated key lines (a repeated key is not documented as unioned
# and must not be relied upon).
declare -A LOCAL_TARGETS
declare -A FORWARD_TARGETS
declare -a ALIAS_ORDER
declare -A ALIAS_SEEN

while read -r alias_addr target_addr; do
	if [[ -z "${ALIAS_SEEN[$alias_addr]:-}" ]]; then
		ALIAS_SEEN["$alias_addr"]=1
		ALIAS_ORDER+=("$alias_addr")
	fi
	target_domain="${target_addr#*@}"
	if [[ -n "${CANON_DOMAINS[$target_domain]:-}" ]] && is_mailbox "$target_addr"; then
		if [[ -n "${LOCAL_TARGETS[$alias_addr]:-}" ]]; then
			LOCAL_TARGETS["$alias_addr"]="${LOCAL_TARGETS[$alias_addr]},$target_addr"
		else
			LOCAL_TARGETS["$alias_addr"]="$target_addr"
		fi
	else
		if [[ -n "${FORWARD_TARGETS[$alias_addr]:-}" ]]; then
			FORWARD_TARGETS["$alias_addr"]="${FORWARD_TARGETS[$alias_addr]},$target_addr"
		else
			FORWARD_TARGETS["$alias_addr"]="$target_addr"
		fi
	fi
done < <(strip_comments "$BASE/aliases")

# A single alias cannot have both local and external targets: virtual
# <virtual_local> (LMTP delivery) and virtual <virtual_forward>
# (relay) are two separate OpenSMTPD actions, matched by two separate
# rcpt-to tables - only one action fires per recipient, so a mixed
# alias would silently deliver to only one half of its targets.
# Fail-closed here rather than generate something that looks complete
# but only half-works.
for alias_addr in "${ALIAS_ORDER[@]}"; do
	if [[ -n "${LOCAL_TARGETS[$alias_addr]:-}" && -n "${FORWARD_TARGETS[$alias_addr]:-}" ]]; then
		echo "[ERROR] alias has both local and external targets, which is not supported: $alias_addr (local: ${LOCAL_TARGETS[$alias_addr]}; external: ${FORWARD_TARGETS[$alias_addr]})" >&2
		exit 1
	fi
	if [[ -n "${LOCAL_TARGETS[$alias_addr]:-}" ]]; then
		echo "$alias_addr ${LOCAL_TARGETS[$alias_addr]}" >> "$OUT/virtual-local"
		echo "$alias_addr" >> "$OUT/smtpd-local-recipients"
	else
		echo "$alias_addr ${FORWARD_TARGETS[$alias_addr]}" >> "$OUT/virtual-forward"
		echo "$alias_addr" >> "$OUT/smtpd-forward-recipients"
	fi
done

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
	# value may itself be a comma-separated list now (multi-recipient
	# alias) - split it, since each individual mailbox address in
	# there needs its own smtpd-senders entry, not one entry keyed by
	# the whole raw comma string.
	IFS=',' read -ra targets <<< "$value"
	for target in "${targets[@]}"; do
		if [[ "$target" == vmail ]]; then
			SENDERS_FOR["$key"]="${SENDERS_FOR[$key]:+${SENDERS_FOR[$key]},}$key"
		else
			SENDERS_FOR["$target"]="${SENDERS_FOR[$target]:+${SENDERS_FOR[$target]},}$key"
		fi
	done
done < "$OUT/virtual-local"

: > "$OUT/smtpd-senders"
for mailbox in "${!SENDERS_FOR[@]}"; do
	echo "$mailbox ${SENDERS_FOR[$mailbox]}" >> "$OUT/smtpd-senders"
done
sort -o "$OUT/smtpd-senders" "$OUT/smtpd-senders"
chmod 644 "$OUT/smtpd-senders"

echo "[OK] generated smtpd-senders ($(wc -l < "$OUT/smtpd-senders") entries)"
