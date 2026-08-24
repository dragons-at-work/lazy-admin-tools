# lazy-admin-tools: mailserver-generate - TLS certificate verification
# Sourced by mailserver-generate.sh after hosting.sh. Relies on $BASE,
# $OUT already being set, and read_domain_config()/strip_comments()
# already defined. Not standalone executable. Produces PKI_BLOCKS,
# PKI_NAMES, PKI_REFS as globals for the caller to assemble
# smtpd-mailtls.conf with.

# --- smtpd-mailtls.conf inputs: pki blocks for every canonical
#     domain. Fail-closed: every active domain must already have a
#     matching, name-complete certificate deployed under
#     /etc/ssl/local/ before this succeeds - no domain silently ends
#     up without TLS because its certificate was missing or stale.
#     Certificates themselves are managed by the separate cert/
#     toolset (cert-add, cert-deploy); this only reads what has
#     already been deployed there and refuses to proceed if it is not
#     what mail expects. ---
TLS_CERT_ROOT=/etc/ssl/local

if ! command -v openssl >/dev/null 2>&1; then
	echo "[ERROR] openssl not found - required to verify mail TLS certificates" >&2
	exit 1
fi

PKI_BLOCKS=""
PKI_NAMES=()
DOVECOT_SNI_BLOCKS=""

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

	# Certificate must cover the conventional mx/smtp/imap hostnames
	# for this domain, at minimum - a certificate missing any of them
	# is stale or was issued wrong. Autoconfig, if enabled, checks its
	# own additional required hostname separately (see autoconfig.sh) -
	# this loop's job is only the mail protocols that are always
	# mandatory.
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

	# Dovecot has no equivalent of OpenSMTPD's multi-name "pki"
	# declaration - each additional domain needs its own local_name
	# block(s), matched by the hostname the client actually connected
	# to. Without this, Dovecot falls back to whatever ssl_cert a
	# host-level default names - correct for exactly one domain and
	# silently wrong for every other, as found manually on
	# schwarzer-genealogie.de before this was added.
	#
	# Two hostnames get a block, both pointing at the same cert/key
	# (the cert already covers both as SANs): IMAP_HOST, the intended
	# per-domain IMAP hostname, and MX_HOST (mail.<domain>) - legacy
	# tooling and some clients still connect for IMAP via the
	# mail.<domain> name rather than imap.<domain>, and without an
	# explicit block for it too, IMAP over mail.<domain> silently
	# fell back to the host-level default cert, as found manually on
	# dragons-at-work.de (biocodie.de's certificate was served).
	# SMTP_HOST is deliberately not covered here - submission runs
	# through OpenSMTPD in this project, not Dovecot.
	DOVECOT_SNI_BLOCKS="$DOVECOT_SNI_BLOCKS
local_name $IMAP_HOST {
  ssl_server_cert_file = $CERT
  ssl_server_key_file = $KEY
}"
	if [[ "$MX_HOST" != "$IMAP_HOST" ]]; then
		DOVECOT_SNI_BLOCKS="$DOVECOT_SNI_BLOCKS
local_name $MX_HOST {
  ssl_server_cert_file = $CERT
  ssl_server_key_file = $KEY
}"
	fi

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

# --- dovecot-ssl-sni.conf: one local_name block per domain, written
#     here directly (not returned to the orchestrator) since it needs
#     no further assembly with anything from dkim.sh/autoconfig.sh -
#     same pattern autoconfig.sh uses for nginx-autoconfig.conf.
#     mailserver-deploy owns installing this into Dovecot's own
#     conf.d, the same as it already does for the rspamd and nginx
#     artifacts. No host-level default certificate is defined or
#     assumed here - whichever domain's local_name block Dovecot
#     picked as its own prior default (if any) is left untouched by
#     this file; it only adds explicit per-domain matches. ---
{
	echo "# Generated by mailserver-generate - do not edit, changes will be lost."
	echo "# mailserver-deploy installs this into Dovecot's own conf.d/."
	echo "# One local_name block per canonical domain, so IMAP/POP3 TLS"
	echo "# presents the matching certificate instead of silently falling"
	echo "# back to whichever domain a host-level default names."
	echo "$DOVECOT_SNI_BLOCKS"
} > "$OUT/dovecot-ssl-sni.conf"
chmod 644 "$OUT/dovecot-ssl-sni.conf"
echo "[OK] generated dovecot-ssl-sni.conf (${#PKI_NAMES[@]} domain(s))"
