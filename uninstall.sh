#!/bin/sh
# Removes Claude Warmup from an OpenWrt router. Run this ON the router (via SSH).

echo "==> Removing cron entry"
if [ -f /etc/crontabs/root ]; then
	sed -i '/# BEGIN claudewarmup/,/# END claudewarmup/d' /etc/crontabs/root
	/etc/init.d/cron restart >/dev/null 2>&1
fi

echo "==> Removing files"
rm -f /usr/bin/claude-warmup.sh
rm -f /www/cgi-bin/claudewarmup
rm -rf /www/claudewarmup
rm -f /usr/share/luci/menu.d/luci-app-claudewarmup.json
rm -f /www/luci-static/resources/view/services/claudewarmup.js
rm -f /etc/config/claudewarmup

printf "Also delete /etc/claudewarmup (contains your OAuth token + page password)? [y/N] "
read -r ans
case "$ans" in
	y|Y) rm -rf /etc/claudewarmup; echo "Removed." ;;
	*) echo "Kept /etc/claudewarmup (token + webauth + logs)." ;;
esac

echo "==> Done."
