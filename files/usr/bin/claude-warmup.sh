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
ERROR_FILE="${STATE_FILE}.error"
TOKEN_ISSUED_FILE="${STATE_FILE}.token_issued"
TOKEN_VALIDITY_SECONDS=31536000
LOG_FILE=$(uci -q get $CONF.settings.log_file); LOG_FILE=${LOG_FILE:-/etc/claudewarmup/warmup.log}
MESSAGE=$(uci -q get $CONF.settings.message); MESSAGE=${MESSAGE:-"Automated warm-up ping to reset the Claude 5h usage window. Reply with a short acknowledgement."}

FAIL_THRESHOLD=3

log() {
	ts=$(date +%s)
	echo "$ts $1" >> "$LOG_FILE"
	tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

record_failure() {
	reason="$1"
	immediate="$2"
	count=0
	[ -s "$ERROR_FILE" ] && count=$(cut -d: -f1 "$ERROR_FILE" 2>/dev/null)
	count=$((count + 1))
	if [ "$immediate" = "1" ] || [ "$count" -ge "$FAIL_THRESHOLD" ]; then
		echo "${count}:${reason}:1" > "$ERROR_FILE"
	else
		echo "${count}:${reason}:0" > "$ERROR_FILE"
	fi
}

clear_failure() {
	rm -f "$ERROR_FILE"
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
		record_failure "network" 0
		log "ERROR: curl failed (rc=$curl_rc)"
		return 1
	fi

	if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
		rm -f "$hdrfile"
		record_failure "unauthorized" 1
		log "ERROR: warmup request failed (http=$http_code) - token likely invalid/expired/revoked"
		return 1
	fi

	if [ "$http_code" != "200" ]; then
		rm -f "$hdrfile"
		record_failure "http_$http_code" 0
		log "ERROR: warmup request failed (http=$http_code)"
		return 1
	fi

	hdrs=$(tr -d '\r' < "$hdrfile")
	rm -f "$hdrfile"
	reset=$(echo "$hdrs"    | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-reset"{print $2}')
	util=$(echo "$hdrs"     | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-5h-utilization"{print $2}')
	reset7d=$(echo "$hdrs"  | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-7d-reset"{print $2}')
	util7d=$(echo "$hdrs"   | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-7d-utilization"{print $2}')
	ustatus=$(echo "$hdrs"  | awk -F': ' 'tolower($1)=="anthropic-ratelimit-unified-status"{print $2}')

	clear_failure

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
	now=$(date +%s)

	if [ "$mode" = "fixed" ]; then
		fixed_hour=$(uci -q get $CONF.settings.fixed_hour); fixed_hour=${fixed_hour:-0}
		fixed_minute=$(uci -q get $CONF.settings.fixed_minute); fixed_minute=${fixed_minute:-1}
		today=$(date +%Y-%m-%d)
		today_start=$(date -d "$today $fixed_hour:$fixed_minute" +%s 2>/dev/null)
		if [ -n "$today_start" ] && [ "$now" -lt "$today_start" ]; then
			return 0
		fi
	fi

	reset=0
	[ -s "$STATE_FILE" ] && reset=$(cut -d: -f1 "$STATE_FILE")
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

	has_error=false
	error_reason=""
	if [ -s "$ERROR_FILE" ]; then
		err_alarm=$(cut -d: -f3 "$ERROR_FILE" 2>/dev/null)
		error_reason=$(cut -d: -f2 "$ERROR_FILE" 2>/dev/null)
		[ "$err_alarm" = "1" ] && has_error=true
	fi

	token_issued=0
	[ -s "$TOKEN_ISSUED_FILE" ] && token_issued=$(cat "$TOKEN_ISSUED_FILE")
	token_expiry=0
	token_days_left=0
	if [ "$token_issued" -gt 0 ] 2>/dev/null; then
		token_expiry=$((token_issued + TOKEN_VALIDITY_SECONDS))
		token_days_left=$(( (token_expiry - now) / 86400 ))
		[ "$token_days_left" -lt 0 ] && token_days_left=0
	fi

	printf '{"enabled":%s,"mode":"%s","fixed_hour":%s,"fixed_minute":%s,"last_fire":%s,"window_end":%s,"utilization":%s,"remaining_seconds":%s,"active":%s,"window7d_end":%s,"utilization7d":%s,"remaining7d_seconds":%s,"account_status":"%s","has_error":%s,"error_reason":"%s","token_expiry":%s,"token_days_left":%s,"now":%s}\n' \
		"$en" "$mode" "$fixed_hour" "$fixed_minute" "$last_fire" "$reset" "${util:-0}" "$remaining" "$active" "${reset7d:-0}" "${util7d:-0}" "$remaining7d" "$ustatus" "$has_error" "$error_reason" "$token_expiry" "$token_days_left" "$now"
}

do_settoken() {
	d="$1"
	epoch=$(date -d "$d" +%s 2>/dev/null)
	if [ -n "$epoch" ]; then
		echo "$epoch" > "$TOKEN_ISSUED_FILE"
		log "INFO: token issue date set to $d (epoch=$epoch)"
	fi
}

do_log() {
	esc=$(tail -n 100 "$LOG_FILE" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
	printf '{"log":"%s"}\n' "$esc"
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
		echo "*/5 * * * * /usr/bin/claude-warmup.sh check"
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
	log) do_log ;;
	settoken) do_settoken "$2" ;;
	*) echo "Usage: $0 {check|fire|status|apply|log|settoken}" >&2; exit 1 ;;
esac
