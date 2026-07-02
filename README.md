# Claude Warmup for OpenWrt

Keeps your **Claude Pro/Max subscription's rolling 5-hour usage window** warm by sending a tiny Haiku ping from your OpenWrt router — no PC, Raspberry Pi, or cloud service required.

Not affiliated with Anthropic. Community tool, MIT licensed.

## The problem

Claude's usage limit is a **rolling 5-hour window** that starts on your *first* message of the day, not at midnight. Start working at noon, and your window resets at noon — even if you're mid-task at 4:55pm.

## How it works

1. Runs entirely on the router (tested on a Xiaomi AX3600, aarch64, OpenWrt 25.12 — should work on any OpenWrt device with enough flash/RAM for a ~5KB shell script).
2. Uses the **official** `claude setup-token` command to generate a long-lived OAuth token scoped to `user:inference` only — the same mechanism Anthropic documents for CI/headless use (e.g. GitHub Actions). This is *not* a scraped session token or a spoofed client.
3. A cron job on the router periodically (or at a fixed time) sends a minimal `POST` to `api.anthropic.com/v1/messages` using that token, authenticating against your subscription's usage window.
4. The response carries real rate-limit headers (`anthropic-ratelimit-unified-5h-reset`, `-utilization`) with the **actual server-side window reset time** — this is what's tracked and displayed, not a local guess. That matters because the window can already be running from other usage (Claude Code, claude.ai, mobile app) before this tool ever pings; a purely local "last ping + 5h" estimate would be wrong in that case. Reading the header keeps it accurate. This requires `curl` (installed automatically) since the router's built-in `wget` can't read response headers.
5. Two modes:
   - **Keep warm** (default): checks every 5 minutes, refires the instant the previous window has expired — your window is effectively always fresh.
   - **Fixed time**: fires once daily at a time you choose (00:00–23:59), e.g. right after midnight so your window has reset by the time you sit down to work.
5. A small web UI on the router lets you switch modes and pick the time, and shows how much of the current window is left. It also shows your **5h and 7-day usage** (percent utilized + reset time), since Pro/Max subscriptions are capped by both. It's linked from LuCI under **Services → Claude Warmup**.

## Requirements

- OpenWrt router with `apk` (25.12+) and cron (`/etc/init.d/cron`) — both present on stock OpenWrt. The installer pulls in `curl` (~500KB) automatically.
- A Claude Pro or Max subscription.
- Claude Code installed on any PC, just once, to generate the token.

## Install

SSH into your router, then:

```sh
wget -qO- https://raw.githubusercontent.com/BrightRaider/claude-code-warmup-openwrt/main/install.sh | sh
```

You'll be prompted for the token the first time (see below). The installer places files under `/etc/claudewarmup`, `/usr/bin`, and `/www`, and sets up the cron job.

### Generating the token

On a PC with [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged into your subscription:

```sh
claude setup-token
```

This opens a browser login and prints a token like `sk-ant-oat01-...`, valid for **1 year**. Copy it — it's shown only once. Paste it when `install.sh` asks for it.

**Treat this token like a password.** Anyone with it can send messages using your subscription's quota. The installer stores it at `/etc/claudewarmup/token` with `chmod 600` (root-only).

## Using it

Open `http://<router-ip>/claudewarmup/` (or LuCI → Services → Claude Warmup). From there you can:

- Toggle the whole thing on/off
- Switch between **Keep warm** and **Fixed time** mode, and pick the time
- See how much of the current 5h window is left
- Fire a manual test ping

## Security note

The web page at `/claudewarmup/` is protected by a **password generated during install**, printed at the end of `install.sh` and stored at `/etc/claudewarmup/webauth`. Anyone without it gets HTTP 403 from the backend, including read-only status. This matters if any less-trusted device (guest Wi-Fi, IoT, VPN clients) can reach your router's LAN-facing services — they can't see or change anything here without that password. It's a shared page-level secret, not a full user/session system; treat it like a simple gate, not a bank vault.

## Uninstall

```sh
wget -qO- https://raw.githubusercontent.com/BrightRaider/claude-code-warmup-openwrt/main/uninstall.sh | sh
```

## Why this is safe (and what would not be)

This project only ever calls the API through a token minted by Anthropic's own `claude setup-token` command, using the same request shape Claude Code itself uses. It does not extract session credentials from `~/.claude/.credentials.json`, does not spoof a browser session, and does not automate the claude.ai website. If you're adapting this for something else, keep it that way — anything that impersonates a client using scraped credentials risks your account.

## License

MIT
