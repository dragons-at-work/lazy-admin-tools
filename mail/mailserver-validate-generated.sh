#!/bin/bash
# lazy-admin-tools: Validate generated artifacts against OpenSMTPD/Dovecot
# Usage: mailserver-validate-generated [--dir DIR]
#
# Builds a throwaway smtpd.conf that includes the real, generated
# smtpd-mailhosting.conf and smtpd-mailtls.conf fragments from DIR
# (default: /etc/mailserver/generated), and a throwaway dovecot.conf
# referencing DIR/dovecot-users. Runs "smtpd -n" / "doveconf -n"
# against them. Also validates rspamd-dkim_signing.conf as standalone
# UCL via "rspamadm lua" (see the DKIM section below for why
# "rspamadm configtest" does not actually work for this). Never
# touches the production /etc/smtpd.conf, /etc/dovecot, or
# /etc/rspamd.
#
# mailserver-deploy calls this with --dir pointing at a staged
# generation directory, so a new generation can be fully validated
# before it is ever promoted to be the live "generated" target.
#
# Deliberately validates the exact generated fragment via "include",
# rather than reconstructing an equivalent config here - two separate
# implementations of the same OpenSMTPD rules would let a bug in one
# go unnoticed by the other.
#
# This only proves the target programs accept the generated syntax -
# not that the running services actually work with it. Live checks
# (doveadm user, etc.) belong to mailserver-deploy's post-deploy
# verification, since doveadm talks to the running dovecot process
# via /run/dovecot/auth-userdb regardless of -c, making an isolated
# pre-deploy user lookup impossible on a host with dovecot already
# running.
#
# The "listen on localhost" line below is only for this throwaway
# config, to give smtpd-mailhosting.conf's <localdomains> match
# something to test against. It is NOT something the real host
# config should also have alongside smtpd-mailtls.conf's port 25/587
# listeners - "smtpd -n" only checks syntax and never binds a socket,
# so it cannot catch the real host actually failing to start with
# "dispatcher: listen: Address already in use" the way a duplicate
# listener on the same port does at runtime. See architecture.md.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# --- Configuration ---
BASE=/etc/mailserver
GEN="$BASE/generated"
# --- End configuration ---

if [[ "${1:-}" == "--dir" ]]; then
	if [[ -z "${2:-}" ]]; then
		echo "Usage: mailserver-validate-generated [--dir DIR]" >&2
		exit 2
	fi
	GEN="$2"
elif [[ -n "${1:-}" ]]; then
	echo "Usage: mailserver-validate-generated [--dir DIR]" >&2
	exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

for f in smtpd-domains smtpd-local-recipients smtpd-forward-recipients virtual-local virtual-forward dovecot-users smtpd-auth smtpd-senders smtpd-mailhosting.conf smtpd-mailtls.conf dovecot-ssl-sni.conf rspamd-dkim_signing.conf nginx-autoconfig.conf; do
	if [[ ! -f "$GEN/$f" ]]; then
		echo "[ERROR] $GEN/$f not found - run mailserver-generate first" >&2
		exit 1
	fi
done

TMP_SMTPD_CONF=$(mktemp /tmp/mailserver-validate-smtpd.XXXXXX.conf)
TMP_ALIASES=$(mktemp /tmp/mailserver-validate-aliases.XXXXXX)
TMP_DOVECOT_CONF=$(mktemp /tmp/mailserver-validate-dovecot.XXXXXX.conf)

cleanup() { rm -f "$TMP_SMTPD_CONF" "$TMP_ALIASES" "$TMP_DOVECOT_CONF"; }
trap cleanup EXIT

ERRORS=0

# --- OpenSMTPD: validate the real generated fragment via include,
#     with a minimal host shell around it (aliases table, localdomains,
#     a no-op outbound action) standing in for the production host
#     config that the fragment expects to be embedded in ---
: > "$TMP_ALIASES"

cat > "$TMP_SMTPD_CONF" << EOF
table aliases file:$TMP_ALIASES
table localdomains { "validator-host", "localhost" }

listen on localhost

include "$GEN/smtpd-mailhosting.conf"
include "$GEN/smtpd-mailtls.conf"

action "outbound" relay

match from local for any action "outbound"
EOF

if smtpd -f "$TMP_SMTPD_CONF" -n; then
	echo "[OK] generated smtpd-mailhosting.conf and smtpd-mailtls.conf are valid ($GEN)"
else
	echo "[ERROR] generated smtpd-mailhosting.conf or smtpd-mailtls.conf is invalid ($GEN)" >&2
	ERRORS=$((ERRORS + 1))
fi

# --- Dovecot: validate config referencing the generated passwd-file ---
cat > "$TMP_DOVECOT_CONF" << EOF
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0
mail_driver = maildir
mail_home = /var/vmail/%{user | domain}/%{user | username}
mail_path = %{home}
mail_uid = vmail
mail_gid = vmail
auth_username_format = %{user | lower}
passdb passwd-file {
  default_password_scheme = SHA512-CRYPT
  passwd_file_path = $GEN/dovecot-users
}
userdb static {
  fields {
    uid = vmail
    gid = vmail
  }
}
EOF

# Real generated content, not reconstructed here - same reasoning as
# the OpenSMTPD include above: a second hand-written equivalent could
# drift from what mailserver-deploy actually installs.
cat "$GEN/dovecot-ssl-sni.conf" >> "$TMP_DOVECOT_CONF"

if doveconf -c "$TMP_DOVECOT_CONF" -n > /dev/null; then
	echo "[OK] generated Dovecot configuration is valid ($GEN)"
else
	echo "[ERROR] generated Dovecot configuration is invalid ($GEN)" >&2
	ERRORS=$((ERRORS + 1))
fi

echo ""

# --- Rspamd: validate the generated DKIM fragment as a standalone UCL
#     document. Deliberately NOT using "rspamadm configtest" against a
#     copied /etc/rspamd tree - verified experimentally that this does
#     not work: rspamd's $LOCAL_CONFDIR macro resolves to the real,
#     compiled-in /etc/rspamd regardless of the -c flag, so a copied
#     tree's local.d/dkim_signing.conf is silently never read; even
#     intentionally broken UCL (unbalanced braces, garbage text)
#     passed "configtest" as "syntax OK" in testing. Using
#     "rspamadm lua" with the ucl parser library to parse the
#     generated file directly does not merge it into the dkim_signing
#     module's context, so this cannot catch every possible semantic
#     problem (e.g. a domain block rspamd's module schema would
#     reject) - but it does reliably catch actual UCL syntax errors,
#     which configtest was proven not to. Never touches the real
#     /etc/rspamd. Skipped gracefully (not an error) on hosts without
#     rspamd installed - dkim_backend can be "none" there, in which
#     case the generated file is just a disabled placeholder anyway. ---
if command -v rspamadm >/dev/null 2>&1; then
	TMP_UCL_CHECK=$(mktemp /tmp/mailserver-validate-ucl.XXXXXX.lua)
	trap 'rm -f "$TMP_UCL_CHECK"; cleanup' EXIT

	cat > "$TMP_UCL_CHECK" << 'LUAEOF'
local path = arg[1]
local ucl = require "ucl"
local parser = ucl.parser()
local ok, err = parser:parse_file(path)
if not ok then
	print("PARSE ERROR: " .. tostring(err))
	os.exit(1)
end
os.exit(0)
LUAEOF

	if rspamadm lua -a "$GEN/rspamd-dkim_signing.conf" "$TMP_UCL_CHECK" >/dev/null 2>&1; then
		echo "[OK] generated rspamd-dkim_signing.conf is valid UCL ($GEN)"
	else
		echo "[ERROR] generated rspamd-dkim_signing.conf has invalid UCL syntax ($GEN)" >&2
		rspamadm lua -a "$GEN/rspamd-dkim_signing.conf" "$TMP_UCL_CHECK" >&2 || true
		ERRORS=$((ERRORS + 1))
	fi
else
	echo "[INFO] rspamadm not found - skipping rspamd-dkim_signing.conf UCL check (not an error: this host may not use dkim_backend = rspamd)"
fi

# --- nginx: validate the generated autoconfig fragment as real nginx
#     syntax, using a minimal throwaway wrapper config that only
#     includes the fragment - unlike rspamd's configtest, nginx's -c
#     flag genuinely controls what gets read, so this is a real check,
#     not just a standalone parse. Never touches the real
#     /etc/nginx. Skipped gracefully (not an error) on hosts without
#     nginx installed - autoconfig_backend can be "none" there, in
#     which case the generated file is just a disabled placeholder.
#     Note: this check actually binds no sockets (nginx -t only tests
#     config, does not start), but on a host with IPv6 disabled at the
#     kernel level "listen [::]" can still fail this test with a
#     socket-family error unrelated to syntax - not seen as an issue
#     on real mail hosts, which already need IPv6 for MX/SPF anyway. ---
if command -v nginx >/dev/null 2>&1; then
	TMP_NGINX_CONF=$(mktemp /tmp/mailserver-validate-nginx.XXXXXX.conf)
	trap 'rm -f "$TMP_NGINX_CONF"; cleanup' EXIT

	cat > "$TMP_NGINX_CONF" << EOF
events {}
http {
	include $GEN/nginx-autoconfig.conf;
}
EOF

	if nginx -t -c "$TMP_NGINX_CONF" >/dev/null 2>&1; then
		echo "[OK] generated nginx-autoconfig.conf is valid nginx syntax ($GEN)"
	else
		echo "[ERROR] generated nginx-autoconfig.conf has invalid nginx syntax ($GEN)" >&2
		nginx -t -c "$TMP_NGINX_CONF" >&2 || true
		ERRORS=$((ERRORS + 1))
	fi
else
	echo "[INFO] nginx not found - skipping nginx-autoconfig.conf syntax check (not an error: this host may not use autoconfig_backend = nginx)"
fi

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
	echo "[OK] all generated artifacts are valid"
else
	echo "[ERROR] generated artifacts have $ERRORS total problem(s)"
fi
echo ""
echo "-- lazy-admin-tools - dragons@work"

exit "$ERRORS"
