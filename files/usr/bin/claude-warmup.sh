#!/bin/sh
# claude-warmup.sh - keeps a Claude.ai subscription's rolling 5h usage window
# warm by sending a tiny Haiku ping, using the official `claude setup-token`
# long-lived OAuth token. Actions: check | fire | status | apply

CONF=claudewarmup
WINDOW_SECONDS=18000  # 5 hours
MODEL="claude-haiku-4-5-20251001"

TOKEN_FILE=$(uci -q get $CONF.settings.token_file); TOKEN_FILE=${TOKEN_FILE:-/etc/claudewarmup/token}
STATE_FILE=$(uci -q get $CONF.settings.state_file); STATE_FILE=${STATE_FILE:-/etc/claudewarmup/state}
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
	out=$(wget -q -O - \
		--header="Content-Type: application/json" \
		--header="anthropic-version: 2023-06-01" \
		--header="anthropic-beta: claude-code-20250219,oauth-2025-04-20" \
		--header="Authorization: Bearer $token" \
		--post-data="$body" \
		--timeout=20 \
		"https://api.anthropic.com/v1/messages" 2>&1)
	rc=$?
	if [ $rc -eq 0 ]; then
		date +%s > "$STATE_FILE"
		log "OK: warmup sent"
		return 0
	else
		log "ERROR: warmup request failed (rc=$rc): $out"
		return 1
	fi
}

do_check() {
	enabled=$(uci -q get $CONF.settings.enabled); enabled=${enabled:-1}
	[ "$enabled" = "1" ] || return 0

	mode=$(uci -q get $CONF.settings.mode); mode=${mode:-keepwarm}

	if [ "$mode" = "fixed" ]; then
		fire
		return $?
	fi

	last=0
	[ -s "$STATE_FILE" ] && last=$(cat "$STATE_FILE")
	now=$(date +%s)
	elapsed=$((now - last))
	if [ "$last" -eq 0 ] || [ "$elapsed" -ge "$WINDOW_SECONDS" ]; then
		fire
	fi
}

do_status() {
	enabled=$(uci -q get $CONF.settings.enabled); enabled=${enabled:-1}
	mode=$(uci -q get $CONF.settings.mode); mode=${mode:-keepwarm}
	fixed_hour=$(uci -q get $CONF.settings.fixed_hour); fixed_hour=${fixed_hour:-0}
	fixed_minute=$(uci -q get $CONF.settings.fixed_minute); fixed_minute=${fixed_minute:-1}

	last=0
	[ -s "$STATE_FILE" ] && last=$(cat "$STATE_FILE")
	now=$(date +%s)
	if [ "$last" -gt 0 ]; then
		end=$((last + WINDOW_SECONDS))
		remaining=$((end - now))
		[ "$remaining" -lt 0 ] && remaining=0
	else
		end=0
		remaining=0
	fi
	if [ "$remaining" -gt 0 ]; then active=true; else active=false; fi
	if [ "$enabled" = "1" ]; then en=true; else en=false; fi

	printf '{"enabled":%s,"mode":"%s","fixed_hour":%s,"fixed_minute":%s,"last_fire":%s,"window_end":%s,"remaining_seconds":%s,"active":%s,"now":%s}\n' \
		"$en" "$mode" "$fixed_hour" "$fixed_minute" "$last" "$end" "$remaining" "$active" "$now"
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
