#!/bin/sh

. /usr/share/passwall2/utils.sh

positive_number() {
	case "$1" in ''|*[!0-9]*|0) echo "$2" ;; *) echo "$1" ;; esac
}

# A completed HTTP GET with a nonempty body is required; HEAD/204 is not enough.
probe() {
	local endpoint="$1" url="$2" timeout="$3" result
	result=$(/usr/bin/curl --silent --location --fail --noproxy "" \
		--proxy "socks5h://${endpoint}" --connect-timeout "$timeout" \
		--max-time "$timeout" --proto '=http,https' --proto-redir '=http,https' \
		--output /dev/null --write-out '%{http_code} %{size_download}' "$url") || return 1
	printf '%s\n' "$result" | awk '{exit !($1 >= 200 && $1 < 300 && $2 > 0)}'
}

main() {
	local interval timeout threshold failures=0 current endpoint url watched active
	watched=$(config_n_get @global[0] node)
	interval=$(positive_number "$(config_n_get @global[0] vless_failover_interval)" 300)
	timeout=$(positive_number "$(config_n_get @global[0] vless_failover_timeout)" 10)
	threshold=$(positive_number "$(config_n_get @global[0] vless_failover_failures)" 1)
	# Allow the core and DNS to finish starting after every service restart.
	sleep "$interval"
	while [ "$(config_n_get @global[0] enabled 0)" = "1" ] &&
		[ "$(config_n_get @global[0] vless_failover 0)" = "1" ]; do
		current=$(config_n_get @global[0] node)
		[ "$current" = "$watched" ] || return
		[ "$(config_n_get "$current" protocol)" = "vless" ] || return
		[ "$(config_n_get "$current" add_mode)" = "2" ] || return
		url=$(config_n_get @global[0] vless_failover_url https://www.youtube.com/)
		case "$url" in http://*|https://*) ;; *) return ;; esac
		endpoint=$(get_cache_var GLOBAL_SOCKS_server)
		active=$(get_cache_var ACL_GLOBAL_node)
		# Do not inspect a previous configuration during apply/update operations.
		if { [ -n "$active" ] && [ "$active" != "$current" ]; } ||
			[ -f "$LOCK_PATH/${CONFIG}_subscribe.lock" ] ||
			[ -f "$LOCK_PATH/${CONFIG}_rule_update.lock" ]; then
			failures=0
		elif [ -n "$endpoint" ] && probe "$endpoint" "$url" "$timeout"; then
			failures=0
		else
			failures=$((failures + 1))
			log 0 "VLESS failover: HTTP body check failed (${failures}/${threshold}), node ${current}."
			if [ "$failures" -ge "$threshold" ]; then
				# The init script survives stop(), owns the service lock and starts a new worker.
				/etc/init.d/passwall2 vless_failover "$current" && return
				failures=0
			fi
		fi
		sleep "$interval"
	done
}

main
