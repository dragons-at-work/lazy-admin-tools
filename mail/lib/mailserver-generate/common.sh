# lazy-admin-tools: mailserver-generate helpers
# Sourced by mailserver-generate.sh first - defines helpers every
# other lib file in this directory depends on. Not standalone
# executable; relies on $BASE already being set by the caller.

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
