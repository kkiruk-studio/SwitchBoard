# SwitchBoard

A macOS menu bar app that monitors your Claude Code sessions at a glance.

If you run multiple Claude Code instances across different terminal tabs, SwitchBoard shows you what each one is doing — working, waiting for input, or done — in a single dashboard.

![Dashboard](docs/screenshots/Dashboard.png)

<p align="center">
  <img src="docs/screenshots/Popover.png" width="280" alt="Menu bar popover" />
  &nbsp;&nbsp;
  <img src="docs/screenshots/Settings.png" width="380" alt="Settings" />
</p>

## Features

### Session monitoring
- **Real-time status detection** — Monitors `~/.claude/sessions/` and JSONL transcripts
- **Status types:**
  - ⚡ **Working** — Claude is actively processing
  - ⌨️ **Needs Input** — Waiting for your input
  - ✅ **Done** — Turn completed
  - 🌙 **Idle** — Session ended
- **Token usage** — Shows input/output token counts per session

### Dashboard
- **Grid & List views** — Toggle between tile grid and compact list
- **Drag & drop** — Reorder session tiles to your preference
- **Search** — Filter sessions by project name or memo (4+ sessions)
- **Session memos** — Add notes to each session
- **History timeline** — View status transitions over time
- **Click to focus** — Jump to the corresponding terminal/IDE window
- **Terminate sessions** — Kill a session via right-click context menu

### Menu bar
- **Live badge** — Shows active session count (e.g. `1/4`) next to the icon
- **Quick popover** — Left-click for compact session list
- **Dashboard shortcut** — Right-click to open the full dashboard
- **Global hotkey** — `⌘⇧S` from anywhere to toggle the popover

### Notifications
- **macOS notifications** — Get notified when sessions complete or need input
- **Webhooks** — Slack, Discord, Telegram integration
- **Custom messages** — Override default notification text

### Other
- **Auto-updates** — Built-in update checker via Sparkle
- **5 languages** — English, Korean, Japanese, Chinese (Simplified & Traditional)
- **Always on top** — Optional floating window mode
- **Launch at login**

## Requirements

- macOS 13.0 (Ventura) or later
- [Claude Code](https://claude.ai/code) running in one or more terminals

## Installation

### Download (recommended)

1. Download the latest `SwitchBoard.zip` from the [Releases](https://github.com/kkiruk-studio/SwitchBoard/releases) page
2. Unzip and move `SwitchBoard.app` to your `/Applications` folder
3. Launch it

The app is signed with a Developer ID and notarized by Apple, so it should launch without security warnings.

### Build from source

```bash
git clone https://github.com/kkiruk-studio/SwitchBoard.git
cd SwitchBoard
open SwitchBoard.xcodeproj
```

Then build and run in Xcode (⌘R).

## How it works

SwitchBoard reads Claude Code's local session files:

1. **`~/.claude/sessions/*.json`** — Discovers active sessions (PID, project path, start time)
2. **Process status** — Checks if each PID is alive and its CPU usage
3. **JSONL transcripts** — Reads the last messages to determine status

No server required. No network calls (except optional webhooks). Everything is local.

## Settings

- **Poll interval** — 2s / 3s / 5s / 10s
- **Menu bar badge** — Always / Active only / Icon only
- **Always on top** — Keep the window above all others
- **Launch at login** — Start automatically when you log in
- **Notifications** — Enable/disable, custom messages, sound selection
- **Webhooks** — Slack / Discord / Telegram

## Webhook Setup

### Slack
1. Go to your [Slack App settings](https://api.slack.com/apps)
2. Select your app (or create one) → **Incoming Webhooks** → Enable
3. Click **Add New Webhook to Workspace** → Select a channel
4. Copy the Webhook URL → Paste into SwitchBoard settings

### Discord
1. Open your Discord server → **Server Settings** → **Integrations**
2. Click **Webhooks** → **New Webhook**
3. Select a channel → **Copy Webhook URL**
4. Paste into SwitchBoard settings

### Telegram
1. Open Telegram and search for **@BotFather**
2. Send `/newbot` → Follow prompts to name your bot
3. Copy the **Bot Token** (e.g. `123456:ABC-DEF...`) → Paste into SwitchBoard settings
4. Search for **@userinfobot** → Send any message → It replies with your **Chat ID** → Paste into settings
5. **Important:** Send any message to your new bot once — this activates the bot so it can send you notifications

## License

MIT

---

Made by [kkirk studio](https://github.com/kkiruk-studio)
