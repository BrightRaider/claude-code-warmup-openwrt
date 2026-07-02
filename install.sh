#!/bin/sh
# Installs Claude Warmup on an OpenWrt router. Run this ON the router (via SSH).
set -e

REPO="BrightRaider/claude-code-warmup-openwrt"
BASE="https://raw.githubusercontent.com/$REPO/main/files"

echo "==> Installing Claude Warmup"

if ! command -v curl >/dev/null 2>&1; then
	echo "==> Installing curl (needed to read the real rate-limit reset time)"
	apk update
	apk add curl
fi

mkdir -p /etc/claudewarmup /www/claudewarmup /www/luci-static/resources/view/services

if [ ! -s /etc/claudewarmup/token ]; then
	echo
	echo "No OAuth token found yet."
	echo "On a PC with Claude Code installed, run:  claude setup-token"
	echo "It prints a token starting with sk-ant-oat01-... (valid 1 year)."
	echo
	printf "Paste that token here: "
	read -r TOKEN
	umask 077
	printf '%s\n' "$TOKEN" > /etc/claudewarmup/token
	chmod 600 /etc/claudewarmup/token
	echo "Token stored at /etc/claudewarmup/token (chmod 600)."
fi

echo "==> Fetching files"
wget -qO /usr/bin/claude-warmup.sh "$BASE/usr/bin/claude-warmup.sh"
chmod +x /usr/bin/claude-warmup.sh

wget -qO /www/cgi-bin/claudewarmup "$BASE/www/cgi-bin/claudewarmup"
chmod +x /www/cgi-bin/claudewarmup

wget -qO /www/claudewarmup/index.html "$BASE/www/claudewarmup/index.html"
wget -qO /usr/share/luci/menu.d/luci-app-claudewarmup.json "$BASE/usr/share/luci/menu.d/luci-app-claudewarmup.json"
wget -qO /www/luci-static/resources/view/services/claudewarmup.js "$BASE/www/luci-static/resources/view/services/claudewarmup.js"

if [ ! -f /etc/config/claudewarmup ]; then
	wget -qO /etc/config/claudewarmup "$BASE/etc/config/claudewarmup"
fi

/usr/bin/claude-warmup.sh apply

echo
echo "==> Done!"
echo "Open http://<router-ip>/claudewarmup/  or  LuCI -> Services -> Claude Warmup"
