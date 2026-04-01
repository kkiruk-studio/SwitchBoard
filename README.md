# Switchboard

A macOS menu bar app that monitors your Claude Code sessions at a glance.

If you run multiple Claude Code instances across different terminal tabs, Switchboard shows you what each one is doing — working, waiting for input, or done — in a single dashboard.

## Features

- **Real-time status detection** — Monitors `~/.claude/sessions/` and JSONL transcripts to determine each session's state
- **Status types:**
  - ⚡ **Working** — AI is actively processing (high CPU)
  - ✋ **Confirm** — Waiting for tool approval
  - ⌨️ **Input** — Waiting for your input
  - ✅ **Done** — Turn completed
  - 🌙 **Idle** — Session ended
- **Grid & List views** — Toggle between tile grid and compact list (Finder-style)
- **Drag & drop** — Reorder session tiles to your preference
- **Always on top** — Optional floating window mode
- **Menu bar icon** — Changes color based on session states

## Requirements

- macOS 13.0+
- [Claude Code](https://claude.ai/code) running in one or more terminals

## Installation

### Build from source

1. Clone the repo
   ```
   git clone https://github.com/kkiruk/SwitchBoard.git
   ```
2. Open `SwitchBoard.xcodeproj` in Xcode
3. Build and run (⌘R)

## How it works

Switchboard reads Claude Code's local session files:

1. **`~/.claude/sessions/*.json`** — Discovers active sessions (PID, project path, start time)
2. **Process status** — Checks if each PID is alive and its CPU usage
3. **JSONL transcripts** — Reads the last messages to determine if Claude is working, waiting for approval, or finished

No server required. No network calls. Everything is local.

## Settings

- **Poll interval** — 2s / 3s / 5s / 10s
- **Always on top** — Keep the window above all others
- **Launch at login** — Start automatically when you log in

## License

MIT
