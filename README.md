# AIusagebar

A small Windows widget (plus a [macOS version](#macos)) that sits on your taskbar and shows your weekly (7-day) usage for **Claude** and **ChatGPT (Codex)**.

```
ChatGPT  ■■■□□□□□   29% used / 7d   10-14 14:43
Claude   ■□□□□□□□    8% used / 7d   10-13 18:00
```

- Usage bar, percentage, and next reset time
- Resizes to fit the taskbar; drag to move
- Hides automatically while a full-screen app (game, video) is in front
- Starts automatically when you sign in to Windows

## Requirements

- Windows 10 / 11 (nothing else to install — uses the built-in PowerShell 5.1)
- **Claude row:** signed in to Claude Code (the Code tab in the Claude desktop app, or the Claude Code CLI)
- **ChatGPT row:** signed in to Codex (ChatGPT desktop app / Codex CLI)

You can use just one of them. The other row shows `--%`.

## Install

1. Click **Code → Download ZIP** at the top of this page and unzip it.
2. Double-click `Install.cmd`.
   - If "Windows protected your PC" appears, click **More info → Run anyway** (the scripts are not code-signed).
3. The widget appears on your taskbar. Done.

Install location: `%LOCALAPPDATA%\AIusagebar` — you can delete the unzipped folder afterwards.

## Usage

| Action | How |
|---|---|
| Start | Start menu → **AIusagebar** |
| Move | Drag the widget |
| Refresh / Details / Exit | Right-click the widget → Refresh now / Details / Exit |

## Uninstall

Start menu → **Uninstall AIusagebar**, or double-click `Uninstall.cmd`.
Removes the install folder, shortcuts, autostart, position setting, and log. Your Claude / ChatGPT sign-ins are left untouched.

## How it works

| File | Role |
|---|---|
| `AIusagebar.ps1` | The widget itself (WinForms) |
| `Run-Widget.ps1` | Renews the Claude login if needed, then starts the widget |
| `Start AIusagebar.vbs` / `.cmd` | Launch hidden, without a console window |
| `Install.ps1` / `Uninstall.ps1` | Install / uninstall |

- **ChatGPT:** asks the installed Codex app-server for `account/rateLimits/read` to get weekly usage.
- **Claude:** reads usage using the Claude Code login (`~/.claude/.credentials.json`).

### Fixed: "Claude never connects after a reboot"

The Claude desktop app manages its own login and does not refresh `.credentials.json`. The token in that file expires after about 8 hours, so right after boot it was usually expired; the widget then tried to refresh it on its own, failed, and got stuck in a cooldown.

`Run-Widget.ps1` now checks the token before starting the widget and, if it has expired, renews it once using the installed Claude Code CLI (retrying up to 3 times, since the network may not be ready right after sign-in).

## macOS

A native Swift/AppKit version lives in [`mac/`](mac). It opens a small window (not a menu-bar item) with the same two rows, refreshes every 2 minutes, and has a manual **Refresh** button. The UI and the guide (`mac/사용설명서.txt`) are in Korean.

- **Supports:** macOS 12 or later (13+ recommended), Apple Silicon and Intel. The app is compiled on your own Mac for its CPU.
- **Needs:** Apple Command Line Tools (the installer asks macOS to install them if missing; full Xcode is not needed).
- Built and installed on an Apple Silicon Mac; Intel Macs have not been tested yet.

### Install (macOS)

1. Download the ZIP (**Code → Download ZIP**) and unzip it.
2. In Terminal, run:
   ```
   bash ~/Downloads/claude-chatgpt-usage-bar-main/mac/Install.command
   ```
   It builds `AI Usage Bar.app`, runs a parsing self-test, installs to `~/Applications`, registers a LaunchAgent so the window opens at login, and opens the app.
3. Sign in with your own accounts (only once):
   ```
   bash ~/Downloads/claude-chatgpt-usage-bar-main/mac/Setup-Login.command
   ```
   It installs the official Codex CLI / Claude Code if they are missing, then runs `codex login` (ChatGPT account) and `claude auth login` (Claude subscription).
4. Click **Refresh** in the app. If macOS asks for Keychain access to `Claude Code-credentials`, allow it.

Running the scripts with `bash` from Terminal avoids the Gatekeeper warning you get when double-clicking an unsigned `.command` file.

| Action | How |
|---|---|
| Turn off autostart | `bash mac/Disable-Autostart.command` |
| Turn autostart back on | `bash mac/Enable-Autostart.command` |
| Uninstall | Disable autostart, then move `~/Applications/AI Usage Bar.app` to the Trash |

Launching it again brings the existing window to the front, and it refreshes after the Mac wakes from sleep. When a request is rate-limited it honors `Retry-After`; when a refresh fails it keeps showing the last values and says they are stale.

## Notes

- Reading Claude usage relies on an **undocumented endpoint**. It may stop working if Anthropic or OpenAI change things.
- This is an unofficial personal tool and is not affiliated with Anthropic or OpenAI.
- Login tokens are never printed to the screen or the log.

## Troubleshooting

- Claude row shows `Claude login` → sign in to Claude Code again, then right-click the widget → Refresh now
- ChatGPT row shows `codex login` → sign in to Codex / the ChatGPT app again
- Anything else: check `%TEMP%\AIusagebar.log`

## License

[MIT](LICENSE)
