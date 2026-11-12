# Wickbar — Spec (v1)

Wickbar is a native macOS menu-bar app that keeps your long-running terminal commands
alive and visible. It replaces "a terminal tab per server" (e.g. `kanzo`,
`hermes dashboard --no-open`, `tailscale serve ...`) with saved commands that you can
start/stop, watch live in a real terminal view, auto-start on login, and restart on crash.
Agents can configure and control it over MCP.

## Platform & stack
- macOS 14+ (Sonoma), Apple Silicon. Swift 6 toolchain, **Swift 5 language mode** (avoid strict-concurrency churn).
- Swift Package Manager project (no .xcodeproj). Executable target `Wickbar`.
- SwiftUI app: `MenuBarExtra` (style `.window`) + a normal `Window` scene (id `"main"`) + `Settings` scene.
- Dependency: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for PTY process + terminal rendering.
- Not sandboxed (runs arbitrary shell commands) → distributed outside the Mac App Store.
- `scripts/build-app.sh` builds release and assembles `build/Wickbar.app` (Info.plist with
  `LSUIElement=true`, bundle id `com.0sahil.wickbar`, version from a `VERSION` file),
  generates an app icon (.icns) programmatically (flame on a warm rounded-square), and ad-hoc codesigns it.
  `scripts/build-app.sh --install` also copies it to `/Applications/Wickbar.app`.

## Data model
Stored as human-editable JSON at `~/Library/Application Support/Wickbar/config.json`
(write atomically, pretty-printed, sorted keys):
```json
{
  "settings": { "autoStartOnLaunch": true, "mcpEnabled": true, "mcpPort": 9425, "restoreAfterCrash": "ask" },
  "commands": [
    { "id": "UUID", "name": "kanzo", "command": "kanzo", "workingDirectory": "~",
      "environment": {"KEY": "VALUE"}, "autoStart": true,
      "restartPolicy": "onFailure" }
  ]
}
```
- `restartPolicy`: `never` | `onFailure` (non-zero exit / signal) | `always` (any exit not requested by the user).
- `restoreAfterCrash`: `ask` | `always` | `never`.
- Launch-at-login is NOT stored in the file; it is read/written via `SMAppService.mainApp` (status is the source of truth).
- Separate runtime state file `state.json` in the same folder: `{ "cleanShutdown": bool, "runningIds": [UUID] }`,
  updated whenever a command starts/stops and on clean quit. Used for crash recovery.
- If config.json is missing on first launch, create it with an empty command list
  (do not seed the developer's personal commands).
- Watch config.json for external edits (DispatchSource file watcher) and reload, so agents/humans can edit the file directly.
  Reload must not kill running processes whose command definition didn't change.

## Process runtime (the core — get this right)
- Each command runs inside a **PTY** (SwiftTerm `LocalProcess` / forkpty), so CLIs behave exactly like in Terminal (colors, line buffering).
- **Environment / PATH problem**: GUI/login-item apps don't get the user's shell PATH. At app launch,
  resolve the user's login shell (from `getpwuid`, fallback `/bin/zsh`) and capture its environment once by running
  `<shell> -l -i -c 'printf "__WICKBAR_ENV__"; env -0'` (timeout ~10s, parse only after the marker, ignore junk the rc files print).
  Fallback: ProcessInfo env + common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `~/.local/bin`).
  Provide a "Reload shell environment" action.
- Run each command as `<shell> -c "<command>"` (non-interactive, so no job control splits the process group) with
  env = captured env + per-command `environment` overrides + `TERM=xterm-256color`, `COLORTERM=truecolor`.
  `workingDirectory` supports `~` expansion; default home.
- **Stopping**: send SIGTERM to the whole process group (`kill(-pgid, SIGTERM)`) AND to all descendant PIDs
  (walk the tree with `proc_listchildpids` or `pgrep -P`), wait up to 5s, then SIGKILL survivors. No orphaned children holding ports.
- Statuses: `stopped`, `starting`, `running`, `stopping`, `crashed` (exited unexpectedly and not being restarted),
  `restarting` (waiting for backoff). Track pid, start time, last exit code/signal, restart count.
- **Restart policy** with exponential backoff (1s, 2s, 4s … max 30s). If it fails 5 times within 60s, give up → `crashed`.
  A run that stayed up > 60s resets the backoff.
- **Output buffer**: keep the raw byte stream per command in a ring buffer (~2 MB, trim from the front).
  Survives the window being closed. Also log separator lines like `── started 12:01:03 ──` / `── exited (code 1) ──`
  into the buffer (dim ANSI text) so restarts are visible in the scrollback.
- Plain-text log extraction for MCP: strip ANSI/OSC escape sequences, handle `\r` (keep text after last `\r` per line), return last N lines.
- Input: keystrokes typed in the terminal view are forwarded to the PTY (so Ctrl-C, answering prompts, etc. work).
- PTY window size follows the terminal view size (TIOCSWINSZ on resize); default 120x40 when no view is attached.
- **Quit**: `applicationShouldTerminate` → stop all commands gracefully (bounded ~6s total), mark `cleanShutdown=true`, then quit.

## Startup behaviour
1. Load config, mark state `cleanShutdown=false` (after reading the previous value).
2. Capture shell environment.
3. If `settings.autoStartOnLaunch`: start every command with `autoStart=true`.
4. Crash recovery: if previous `cleanShutdown == false` and previous `runningIds` contains commands not already started:
   `always` → start them; `ask` → show a "Restore N commands that were running before Wickbar stopped unexpectedly" banner
   in the menu bar popover and main window with Restore / Dismiss; `never` → nothing.

## UI
### Menu bar
- Icon: SF Symbol `flame` when nothing runs, `flame.fill` when ≥1 runs; show a small count or warning state when something `crashed`
  (e.g. `exclamationmark.triangle` overlay / alternate symbol).
- Popover (`.window` style, ~320pt wide):
  - Restore banner (if any).
  - List of commands: status dot (green running, yellow starting/restarting, red crashed, grey stopped), name,
    uptime or "exited 1", and inline start/stop + restart buttons.
  - Empty state with "Add command…".
  - Footer: Open Wickbar, Start all, Stop all, Settings…, Quit Wickbar.
### Main window
- `NavigationSplitView`: sidebar = commands with status dots (+ add button, context menu: start/stop/restart/edit/duplicate/delete);
  detail = header (name, command in monospace, status, pid, uptime, buttons Start/Stop/Restart/Edit/Clear output)
  and a **live terminal view** (SwiftTerm `TerminalView` in `NSViewRepresentable`) filling the rest.
  On attach: feed the existing buffer, then stream new bytes. Recreate per selected command (`.id`).
- Add/Edit sheet: name, command (multi-line monospace), working directory (text + "Choose…" folder panel),
  environment (KEY=VALUE per line), auto-start toggle, restart policy picker. Validate non-empty name/command.
- Dock icon policy: app is `LSUIElement` (no Dock icon). When the main window is open, switch to `.regular` activation policy
  and activate; when it closes, go back to `.accessory`.
### Settings
- General: Launch Wickbar at login (SMAppService.mainApp register/unregister, show status/errors incl. "requires approval"),
  Auto-start commands when Wickbar launches, Restore after crash (ask/always/never), Reload shell environment.
- MCP: enabled toggle, port, status (listening / error), endpoint URL, and copyable config snippets for
  Claude Code (`claude mcp add --transport http wickbar http://127.0.0.1:9425/mcp`), Hermes (yaml `url:`), and generic JSON.
### Notifications
- `UNUserNotificationCenter` notification when a command crashes / gives up restarting. Fail silently if not authorized.

## MCP server (agents configure & control Wickbar)
- Built into the app, **MCP Streamable HTTP transport**, JSON responses (no SSE needed), endpoint `POST http://127.0.0.1:<port>/mcp`.
  Implement a minimal HTTP/1.1 server with `Network.framework` (`NWListener`), **bound to 127.0.0.1 only**.
  - Validate `Origin` header (reject non-localhost origins, 403) and `Host` header (DNS-rebinding protection).
  - JSON-RPC 2.0: `initialize` (echo client's protocolVersion if supported, else `2025-06-18`; capabilities `{tools:{}}`;
    serverInfo name `wickbar` + version; include `Mcp-Session-Id` header), `notifications/*` → HTTP 202 no body,
    `ping`, `tools/list`, `tools/call`. Batch arrays supported. `GET /mcp` → 405. Unknown method → -32601.
  - Tool errors returned as `result` with `isError: true` and a helpful text message.
  - Handle Content-Length bodies, keep-alive, and partial reads correctly.
  - All state access hops to the main actor.
- Tools (commands can be referenced by `id` or exact/case-insensitive `name` via a `command` argument):
  - `list_commands` — all commands with config + live status (status, pid, uptime_seconds, last_exit_code, restart_count).
  - `get_command` {command}
  - `add_command` {name, command, working_directory?, environment?, auto_start?, restart_policy?, start_now?}
  - `update_command` {command, name?, command_line?, working_directory?, environment?, auto_start?, restart_policy?} — restart if running and the command line/cwd/env changed (say so in the result).
  - `remove_command` {command} — stops it first.
  - `start_command`, `stop_command`, `restart_command` {command}
  - `start_all`, `stop_all`
  - `get_logs` {command, lines? (default 200, max 5000)} — plain text, ANSI stripped.
  - `send_input` {command, text, press_enter? (default true)}
  - `get_settings` / `update_settings` {auto_start_on_launch?, launch_at_login?, restore_after_crash?}
  - Every tool has a JSON Schema `inputSchema` and a clear one-line description.
- Port in use → show error in Settings and menu, don't crash.

## Code layout (suggested)
```
Package.swift
VERSION
Sources/Wickbar/
  App/WickbarApp.swift, AppDelegate.swift
  Model/CommandConfig.swift, AppSettings.swift, ConfigStore.swift, RuntimeState.swift
  Runtime/ShellEnvironment.swift, ManagedProcess.swift, ProcessManager.swift, OutputBuffer.swift, ProcessTree.swift
  MCP/HTTPServer.swift, MCPServer.swift, MCPTools.swift, JSONValue.swift
  UI/MenuBarView.swift, MainWindow.swift, CommandDetailView.swift, CommandEditor.swift, SettingsView.swift, TerminalPane.swift
  System/LoginItem.swift, Notifications.swift
Tests/WickbarTests/  (OutputBuffer/ANSI stripping, config round-trip, JSON-RPC dispatch, command lookup)
scripts/build-app.sh
README.md
```
Keep core logic (config, output buffer, MCP dispatch) separable from AppKit so it is unit-testable
(e.g. a `WickbarCore` library target + thin `Wickbar` executable target).
