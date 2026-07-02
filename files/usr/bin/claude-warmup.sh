#!/bin/sh
# claude-warmup.sh - keeps a Claude.ai subscription's rolling 5h usage window
# warm by sending a tiny Haiku ping, using the official `claude setup-token`
# long-lived OAuth token. Actions: check | fire | status | apply

CONF=claudewarmup
WINDOW_SECONDS=18000  # 5 hours
MODEL="claude-haiku-4-5-20251001"

TOKEN_FILE=$(uci -q get $CONF.settings.token_file); TOKEN_FILE=${TOKEN_FILE:-/etc/claudewarmup/token}
STATE_FILE=$(uci -q get $CONF.settings.state_file); STATE_FILE=${STATE_FILE:-/etc/claudewarmup/state}
LASTFIRE_FILE="${STATE_FILE}.last_fire"
LOG_FILE=$(uci -q get $CONF.settings.log_file); LOG_FILE=${LOG_FILE:-/etc/claudewarmup/warmup.log}
MESSAGE=$(uci -q get $CONF.settings.message); MESSAGE=${MESSAGE:-"Automated warm-up ping to reset the Claude 5h usage window. Reply with a short acknowledgement."}

log() {
	ts=$(date '+%Y-%m-%d %H:%M:%S')
	echo "$ts $1" >> "$LOG_FILE"
	tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

fire() {
	if [ ! -s "$TOKEN_FILE" ]; then
		log "ERROR: token file $TOKEN_FILE missing or empty"
		return 1
	fi
	token=$(cat "$TOKEN_FILE")
	body="{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"$MESSAGE\"}]}"

	hdrfile=$(mktemp)
	http_code=$(curl -sS -o /dev/null -D "$hdrfile" -w '%{http_code}' \
		-H "Content-Type: application/json" \
		-H "anthropic-version: 2023-06-01" \
		-H "anthropic-beta: claude-code-20250219,oauth-2025-04-20" \
		-H "Authorization: Bearer $token" \
		-d "$body" \
		--max-time 20 \
		"https://api.anthropic.com/v1/messages" 2>>"$LOG_FILE")
	curl_rc=$?

	date +%s > "$LASTFIRE_FILE"

	if [ $curl_rc -ne 0 ]; then
		rm -f "$hdrfile"
		log "ERROR: curl failed (rc=$curl_rc)"
		return 1
	fi

	if [ "$http_code" != "200" ]; then
		log "ERROR: warmup request failed (http=$http_code)"
		rm -f "$hdrfile"
		return 1
	fi

	hdrs=$(tr -d '\r' < "$hdrfile")
	rm -f "$hdrfile"
	reset=$(echo "$hdrs"    | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-reset"{print $2}')
	util=$(echo "$hdrs"     | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-utilization"{print $2}')
	reset7d=$(echo "$hdrs"  | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-7d-reset"{print $2}')
	util7d=$(echo "$hdrs"   | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-7d-utilization"{print $2}')
	ustatus=$(echo "$hdrs"  | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-status"{print $2}')

	if [ -n "$reset" ]; then
		echo "${reset}:${util:-0}:${reset7d:-0}:${util7d:-0}:${ustatus:-unknown}" > "$STATE_FILE"
		log "OK: warmup sent, 5h reset=$reset util=$util | 7d reset=$reset7d util=$util7d | status=$ustatus"
	else
		log "WARN: warmup sent but no rate-limit header found in response"
	fi
	return 0
}

do_check() {
	enabled=$(uci -q get $CONF.settings.enabled); enabled=${enabled:-1}
	[ "$enabled" = "1" ] || return 0

	mode=$(uci -q get $CONF.settings.mode); mode=${mode:-keepwarm}

	if [ "$mode" = "fixed" ]; then
		fire
		return $?
	fi

	reset=0
	[ -s "$STATE_FILE" ] && reset=$(cut -d: -f1 "$STATE_FILE")
	now=$(date +%s)
	if [ "$reset" -eq 0 ] || [ "$now" -ge "$reset" ]; then
		fire
	fi
}

do_status() {
	enabled=$(uci -q get $CONF.settings.enabled); enabled=${enabled:-1}
	mode=$(uci -q get $CONF.settings.mode); mode=${mode:-keepwarm}
	fixed_hour=$(uci -q get $CONF.settings.fixed_hour); fixed_hour=${fixed_hour:-0}
	fixed_minute=$(uci -q get $CONF.settings.fixed_minute); fixed_minute=${fixed_minute:-1}

	reset=0; util=0; reset7d=0; util7d=0; ustatus="unknown"
	if [ -s "$STATE_FILE" ]; then
		reset=$(cut -d: -f1 "$STATE_FILE")
		util=$(cut -d: -f2 "$STATE_FILE")
		reset7d=$(cut -d: -f3 "$STATE_FILE")
		util7d=$(cut -d: -f4 "$STATE_FILE")
		ustatus=$(cut -d: -f5 "$STATE_FILE")
	fi
	last_fire=0
	[ -s "$LASTFIRE_FILE" ] && last_fire=$(cat "$LASTFIRE_FILE")

	now=$(date +%s)
	if [ "$reset" -gt 0 ]; then
		remaining=$((reset - now))
		[ "$remaining" -lt 0 ] && remaining=0
	else
		remaining=0
	fi
	remaining7d=0
	if [ "$reset7d" -gt 0 ] 2>/dev/null; then
		remaining7d=$((reset7d - now))
		[ "$remaining7d" -lt 0 ] && remaining7d=0
	fi
	if [ "$remaining" -gt 0 ]; then active=true; else active=false; fi
	if [ "$enabled" = "1" ]; then en=true; else en=false; fi

	printf '{"enabled":%s,"mode":"%s","fixed_hour":%s,"fixed_minute":%s,"last_fire":%s,"window_end":%s,"utilization":%s,"remaining_seconds":%s,"active":%s,"window7d_end":%s,"utilization7d":%s,"remaining7d_seconds":%s,"account_status":"%s","now":%s}\n' \
		"$en" "$mode" "$fixed_hour" "$fixed_minute" "$last_fire" "$reset" "${util:-0}" "$remaining" "$active" "${reset7d:-0}" "${util7d:-0}" "$remaining7d" "$ustatus" "$now"
}

apply_cron() {
	mode=$(uci -q get $CONF.settings.mode); mode=${mode:-keepwarm}
	fixed_hour=$(uci -q get $CONF.settings.fixed_hour); fixed_hour=${fixed_hour:-0}
	fixed_minute=$(uci -q get $CONF.settings.fixed_minute); fixed_minute=${fixed_minute:-1}

	CRONTAB=/etc/crontabs/root
	touch "$CRONTAB"
	sed '/# BEGIN claudewarmup/,/# END claudewarmup/d' "$CRONTAB" > "$CRONTAB.tmp"

	{
		cat "$CRONTAB.tmp"
		echo "# BEGIN claudewarmup"
		if [ "$mode" = "fixed" ]; then
			echo "$fixed_minute $fixed_hour * * * /usr/bin/claude-warmup.sh check"
		else
			echo "*/5 * * * * /usr/bin/claude-warmup.sh check"
		fi
		echo "# END claudewarmup"
	} > "$CRONTAB.new"

	mv "$CRONTAB.new" "$CRONTAB"
	rm -f "$CRONTAB.tmp"
	/etc/init.d/cron restart >/dev/null 2>&1
	log "INFO: cron applied (mode=$mode fixed=$fixed_hour:$fixed_minute)"
}

case "$1" in
	check) do_check ;;
	fire) fire ;;
	status) do_status ;;
	apply) apply_cron ;;
	*) echo "Usage: $0 {check|fire|status|apply}" >&2; exit 1 ;;
esac
