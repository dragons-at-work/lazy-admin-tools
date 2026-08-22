#!/bin/sh
# lazy-admin-tools: uacme hook for http-01 challenges
# Called by uacme as: uacme -h <this-script> ...
# Contract (confirmed against uacme 1.7.x): method type ident token auth
#
# Tested end-to-end on Debian: uacme user -> hook writes token ->
# webserver serves it -> reachable over IPv4 and IPv6 -> cleanup on
# done/failed.

CHALLENGE_DIR="/var/www/acme-challenge/.well-known/acme-challenge"

METHOD="$1"
TYPE="$2"
IDENT="$3"
TOKEN="$4"
KEY_AUTH="$5"

if [ "$TYPE" != "http-01" ]; then
	exit 1
fi

case "$METHOD" in
	begin)
		echo "$KEY_AUTH" > "$CHALLENGE_DIR/$TOKEN"
		chmod 644 "$CHALLENGE_DIR/$TOKEN"
		;;
	done|failed)
		rm -f "$CHALLENGE_DIR/$TOKEN"
		;;
	*)
		exit 1
		;;
esac

exit 0
