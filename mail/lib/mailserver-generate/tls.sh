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
