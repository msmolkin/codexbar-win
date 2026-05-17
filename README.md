# CodexBar for Windows

A lightweight Windows system tray app that monitors your AI coding tool usage — Claude, Codex, and Gemini.

Zero dependencies. Runs on any Windows 10/11 with built-in PowerShell 5.1+.

Inspired by [CodexBar](https://github.com/steipete/CodexBar) for macOS by [@steipete](https://twitter.com/steipete).

## Features

- **Claude** — 5-hour and 7-day usage with reset countdown (OAuth)
- **Codex** — Primary and weekly rate windows with plan detection
- **Gemini** — Session count and model display
- Dynamic tray icon (green/yellow/orange/red based on usage)
- Tooltip showing current usage at a glance
- 60-second auto-refresh (configurable)
- Startup integration (optional)

## Install

```powershell
# Clone or download this folder, then:
.\Start-CodexBar.bat

# Or run directly:
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File CodexBar.ps1
```

## Add to Startup

```powershell
.\Install-Startup.ps1
```

## Authentication

CodexBar reads your existing CLI credentials — no separate login required:

| Provider | Credential Source |
|----------|------------------|
| Claude | `~/.claude/.credentials.json` (from `claude` CLI) |
| Codex | `~/.codex/auth.json` (from `codex` CLI) |
| Gemini | `~/.gemini/settings.json` (from `gemini` CLI) |

## Configuration

| Param | Default | Description |
|-------|---------|-------------|
| `-PollIntervalSeconds` | 60 | How often to refresh usage |
| `-Debug` | false | Print log output to console |

## Security

- Credentials never leave your machine except to their respective provider APIs
- No telemetry, analytics, or phone-home
- All API calls use HTTPS
- Tokens are only sent to: `api.anthropic.com` (Claude), `chatgpt.com` (Codex)

## License

MIT
