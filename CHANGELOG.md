# Changelog

All notable changes to this project are documented here.

## [1.0.0] - 2026-07-02

Initial release.

### Added

- Core warmup mechanism: sends a tiny Haiku ping via the official `claude setup-token` long-lived OAuth token, run entirely on an OpenWrt router.
- Two scheduling modes: **keep warm** continuously, or **fixed time** — stay quiet until a chosen time, then keep warm continuously for the rest of the day, going quiet again overnight.
- Real window tracking read directly from Anthropic's own rate-limit response headers (not a local estimate), so it stays accurate even if the window was started by other usage (Claude Code, claude.ai, mobile app).
- 5-hour and 7-day usage bars with utilization percentage and reset time.
- Token validity tracking — enter the token's issue date once, get a running countdown to its 1-year expiry.
- Error detection: the status box turns red immediately on an invalid/expired/revoked token (HTTP 401/403), or after 3 consecutive failures for transient issues (e.g. network blips), avoiding false alarms from a single hiccup.
- Built-in log viewer (last 100 lines) accessible from the web UI.
- Optional password protection for the web UI — off by default, self-service (set or remove any time from a collapsible panel behind a lock icon).
- German/English UI, auto-detected from the browser, switchable and remembered.
- LuCI integration — reachable from Services → Claude Warmup, not just a standalone URL.
- Live-ticking countdown timer for the active 5h window.
- Install/uninstall scripts (`install.sh` / `uninstall.sh`), README with features overview and screenshot.

### Fixed

- Log timestamps now convert to the browser's local timezone instead of showing the router's raw system time (routers commonly run on UTC).
- The fixed-time picker now correctly converts between the browser's timezone and the router's own timezone, so the time you enter is the time it actually uses — previously a router on UTC would start ~2h later than intended for a CEST user.
- Windows-introduced CRLF line endings were corrupting the deployed shell script; added `.gitattributes` to force LF for shell scripts and the CGI handler.
- `install.sh` now falls back to `opkg` on OpenWrt releases before 25.12, which don't have `apk` — previously the install failed outright on those.

### Changed

- Fixed-time mode now keeps the window continuously warm for the rest of the day after its start time, instead of firing once and going cold until the next day.
- Language switcher uses plain DE/EN text labels instead of flag emojis.
- Access-protection settings are collapsed behind a lock icon instead of always taking up space on the page.
- The page is open by default; a password is opt-in and fully self-managed rather than an installer-generated value shown once in the SSH output.
