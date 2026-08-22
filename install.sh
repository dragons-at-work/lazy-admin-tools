#!/bin/bash
# lazy-admin-tools: install.sh - install toolsets and set up symlinks
# Usage: install.sh [health|mail|cert]... | install.sh --all
#
# Follows the layout already documented in README.md:
#   health/  -> /usr/local/libexec/lazy-admin-tools/health/  (no symlinks,
#               these are unattended cron helpers, not interactive commands)
#   mail/    -> /usr/local/lib/lazy-admin-tools/mail/         + symlinks
#   cert/    -> /usr/local/lib/lazy-admin-tools/cert/          + symlinks
#               (backends/ and hooks/ copied alongside)
#
# Run from the repository root. Idempotent AND clean: each component's
# destination directory is rebuilt from scratch on every run (removed,
# then recreated from the current repository contents), so a file
# removed from the repository does not linger on the target host after
# a later `git pull && install.sh`. Any /usr/local/sbin symlink for a
# command that no longer exists in the rebuilt destination is removed
# as well, rather than left dangling.
#
# This script only places files and creates symlinks. It does not run
# mailserver-init, cert-add, cert-renew-install, or anything else that
# touches live configuration - that stays a deliberate separate step.

set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# --- Configuration ---
LIBEXEC_ROOT=/usr/local/libexec/lazy-admin-tools
LIB_ROOT=/usr/local/lib/lazy-admin-tools
SBIN=/usr/local/sbin
# --- End configuration ---

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] script must run as root" >&2
	exit 1
fi

if [[ $# -eq 0 ]]; then
	echo "Usage: install.sh [health|mail|cert]... | install.sh --all" >&2
	exit 2
fi

if [[ "$1" == --all ]]; then
	COMPONENTS=(health mail cert)
else
	COMPONENTS=("$@")
fi

for c in "${COMPONENTS[@]}"; do
	case "$c" in
		health|mail|cert) ;;
		*)
			echo "[ERROR] unknown component: $c (expected: health, mail, cert)" >&2
			exit 2
			;;
	esac
done

# Remove any /usr/local/sbin symlink that points into $1 but whose
# name is not one of the currently-expected command names in $2
# (space-separated). Only touches symlinks actually pointing into
# this destination - never anything else in $SBIN.
prune_stale_symlinks() {
	local dest="$1"
	local expected=" $2 "
	local link name target
	for link in "$SBIN"/*; do
		[[ -L "$link" ]] || continue
		target="$(readlink -f "$link" 2>/dev/null || true)"
		[[ "$target" == "$dest"/* ]] || continue
		name="$(basename "$link")"
		if [[ "$expected" != *" $name "* ]]; then
			rm -f "$link"
			echo "[OK] removed stale symlink: $link"
		fi
	done
}

install_health() {
	local dest="$LIBEXEC_ROOT/health"
	rm -rf "$dest"
	mkdir -p "$dest"
	cp "$SCRIPT_DIR/health/openbsd-health.sh" "$SCRIPT_DIR/health/debian-health.sh" "$dest/"
	chmod +x "$dest/openbsd-health.sh" "$dest/debian-health.sh"
	echo "[OK] installed health/ -> $dest"
	echo "[INFO] no symlinks created - these are cron-invoked, not interactive commands"
	echo "[INFO] add to crontab yourself, e.g.:"
	echo "       0 6 * * * root $dest/debian-health.sh"
}

install_mail() {
	local dest="$LIB_ROOT/mail"
	rm -rf "$dest"
	mkdir -p "$dest/docs"
	cp "$SCRIPT_DIR"/mail/*.sh "$dest/"
	cp "$SCRIPT_DIR"/mail/README.md "$dest/" 2>/dev/null || true
	cp "$SCRIPT_DIR"/mail/docs/*.md "$dest/docs/" 2>/dev/null || true
	chmod +x "$dest"/*.sh
	echo "[OK] installed mail/ -> $dest"

	local names=""
	for f in "$dest"/*.sh; do
		local name
		name="$(basename "$f" .sh)"
		ln -sf "$f" "$SBIN/$name"
		names="$names $name"
	done
	prune_stale_symlinks "$dest" "$names"
	echo "[OK] symlinked mail commands into $SBIN"
}

install_cert() {
	local dest="$LIB_ROOT/cert"
	rm -rf "$dest"
	mkdir -p "$dest/backends" "$dest/hooks"
	cp "$SCRIPT_DIR"/cert/*.sh "$dest/"
	cp "$SCRIPT_DIR"/cert/README.md "$dest/" 2>/dev/null || true
	cp "$SCRIPT_DIR"/cert/backends/*.sh "$dest/backends/"
	cp "$SCRIPT_DIR"/cert/hooks/*.sh "$dest/hooks/"
	chmod +x "$dest"/*.sh "$dest"/backends/*.sh "$dest"/hooks/*.sh
	echo "[OK] installed cert/ -> $dest"

	local names=""
	for f in "$dest"/*.sh; do
		local name
		name="$(basename "$f" .sh)"
		ln -sf "$f" "$SBIN/$name"
		names="$names $name"
	done
	prune_stale_symlinks "$dest" "$names"
	echo "[OK] symlinked cert commands into $SBIN"
}

for c in "${COMPONENTS[@]}"; do
	echo "=== $c ==="
	case "$c" in
		health) install_health ;;
		mail) install_mail ;;
		cert) install_cert ;;
	esac
	echo ""
done

echo "-- lazy-admin-tools - dragons@work"
