#!/bin/bash
# lazy-admin-tools: Validate generated artifacts against OpenSMTPD/Dovecot
# Usage: mailserver-validate-generated [--dir DIR]
#
# Builds a throwaway smtpd.conf that includes the real, generated
# smtpd-mailhosting.conf fragment from DIR (default:
# /etc/mailserver/generated), and a throwaway dovecot.conf referencing
# DIR/dovecot-users. Runs "smtpd -n" / "doveconf -n" against them.
# Never touches the production /etc/smtpd.conf or /etc/dovecot.
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

for f in smtpd-domains smtpd-local-recipients smtpd-forward-recipients virtual-local virtual-forward dovecot-users smtpd-mailhosting.conf; do
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

action "outbound" relay

match from local for any action "outbound"
EOF

if smtpd -f "$TMP_SMTPD_CONF" -n; then
	echo "[OK] generated smtpd-mailhosting.conf is valid ($GEN)"
else
	echo "[ERROR] generated smtpd-mailhosting.conf is invalid ($GEN)" >&2
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

if doveconf -c "$TMP_DOVECOT_CONF" -n > /dev/null; then
	echo "[OK] generated Dovecot configuration is valid ($GEN)"
else
	echo "[ERROR] generated Dovecot configuration is invalid ($GEN)" >&2
	ERRORS=$((ERRORS + 1))
fi

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
	echo "[OK] generated artifacts are valid"
else
	echo "[ERROR] generated artifacts have $ERRORS problem(s)"
fi
echo ""
echo "-- lazy-admin-tools - dragons@work"

exit "$ERRORS"
