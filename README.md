# Wickbar

[![CI](https://github.com/0sahil/wickbar/actions/workflows/ci.yml/badge.svg)](https://github.com/0sahil/wickbar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A native macOS menu-bar app that keeps your long-running terminal commands alive and visible.

Instead of keeping a terminal tab open per server (`npm run dev`, `tailscale serve 3000`,
`python -m http.server`, …), save them in Wickbar and:

- start / stop / restart them from the menu bar,
- watch their output live in a real terminal view (colors, prompts, Ctrl-C all work: commands run in a PTY),
- auto-start them when Wickbar launches (and launch Wickbar at login),
- restart them automatically when they crash (exponential backoff),
- let agents configure and control them over **MCP**.

Requires macOS 14 (Sonoma) or later on Apple Silicon. Wickbar is not sandboxed (it runs arbitrary shell
commands), so it is distributed outside the Mac App Store.

## Install

Download `Wickbar-<version>.zip` from the [latest release](https://github.com/0sahil/wickbar/releases/latest),
unzip it, and move `Wickbar.app` to `/Applications`. Releases are signed with a Developer ID and notarized by Apple,
so they open without Gatekeeper warnings. Then click the flame in the menu bar.

## Build from source

You need Xcode (or the Swift toolchain) with Swift 6.2 or newer, and network access for SwiftPM to fetch
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

```sh
swift build                       # debug build
swift test                        # unit tests
scripts/build-app.sh              # release build -> build/Wickbar.app (ad-hoc signed, with icon)
scripts/build-app.sh --install    # same, then copies it to /Applications/Wickbar.app
open /Applications/Wickbar.app
```

The version comes from the `VERSION` file. The bundle id is `com.0sahil.wickbar`. The app is an
`LSUIElement` (no Dock icon) until you open its main window.

Local builds are only ad-hoc signed, so macOS may ask you to confirm the first launch
(right-click › Open, or System Settings › Privacy & Security). Maintainers: see
[docs/RELEASING.md](docs/RELEASING.md) for signed, notarized releases.

## Usage

- **Menu bar icon:** `flame` when nothing runs, `flame.fill` when something runs, and a warning
  triangle with a count when a command has crashed.
- **Popover:** every command with a status dot (green running, yellow starting/restarting,
  red crashed, grey stopped), its uptime or exit code, and inline start/stop/restart buttons.
  Click a row to open its output. The footer has Open Wickbar, Start all, Stop all, Settings… and Quit.
- **Main window:** a sidebar of commands (right-click to start/stop/restart/edit/duplicate/delete; drag to reorder)
  and a detail pane with the command, status, pid, uptime, buttons, and a **live terminal**. Type into it
  to answer prompts or press Ctrl-C. Output (the last ~2 MB per command) is kept while the window is closed.
  Restarts appear in the scrollback as dim lines like `── started 12:01:03 ──` / `── exited (code 1) ──`.
- **Add / Edit:** name, command (multi-line), working directory (`~` supported), environment (`KEY=VALUE` per line),
  auto-start, and restart policy.
- **Settings › General:** launch at login, auto-start on launch, restore after crash (ask / always / never),
  reload shell environment.
- **Settings › MCP:** enable/disable, port, status, endpoint, and copyable client config snippets.

### How commands run

- At launch, Wickbar captures your **login shell's environment** once, by running
  `$SHELL -l -i -c 'printf __WICKBAR_ENV__; env -0'` (10 s timeout). That way tools in `~/.cargo/bin`,
  Homebrew, nvm/fnm and so on are on `PATH` even though GUI apps don't normally inherit it.
  Use *Settings › Reload shell environment* after you change your shell profile.
- Each command runs as `$SHELL -c "<command>"` inside a PTY, with that environment plus the command's own
  `environment`, `TERM=xterm-256color` and `COLORTERM=truecolor`.
- **Stop** sends SIGTERM to the command's process group *and* every descendant process. Survivors get
  SIGKILL after 5 s, so nothing is left holding a port.
- **Restart policy:** `never`, `onFailure` (non-zero exit or killed by a signal), or `always` (any exit you didn't request).
  The backoff is 1 s, 2 s, 4 s … up to 30 s. After 5 failures within 60 s Wickbar gives up and marks the command
  **crashed**, and you get a notification. A run that stays up for more than 60 s resets the backoff.
- **Quit** (including `kill`/`killall Wickbar`) stops every command gracefully, within about 6 s, before exiting.
- **Crash recovery:** if Wickbar itself dies unexpectedly, at the next launch it offers to restore the commands that
  were running. The `restoreAfterCrash` setting controls this.

## Config file

Everything lives in `~/Library/Application Support/Wickbar/config.json`. The file is human-editable, and Wickbar
writes it atomically, pretty-printed, with sorted keys. Wickbar **watches the file** and reloads it on change.
Commands whose definition didn't change keep running. A running command whose command line, working directory
or environment changed is restarted.

```json
{
  "commands" : [
    {
      "autoStart" : true,
      "command" : "npm run dev",
      "environment" : { "PORT" : "3000" },
      "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
      "name" : "web",
      "restartPolicy" : "onFailure",
      "workingDirectory" : "~/code/web"
    }
  ],
  "settings" : {
    "autoStartOnLaunch" : true,
    "mcpEnabled" : true,
    "mcpPort" : 9425,
    "restoreAfterCrash" : "ask"
  }
}
```

| Field | Values |
| --- | --- |
| `id` | UUID (generated if missing) |
| `name` | display name, used to refer to the command (case-insensitive) |
| `command` | shell command line |
| `workingDirectory` | path, `~` expanded; defaults to home |
| `environment` | extra `KEY: VALUE` pairs |
| `autoStart` | start when Wickbar launches (if `settings.autoStartOnLaunch`) |
| `restartPolicy` | `never` \| `onFailure` \| `always` |
| `settings.restoreAfterCrash` | `ask` \| `always` \| `never` |
| `settings.mcpEnabled`, `settings.mcpPort` | MCP server on/off and port (default 9425) |

Launch-at-login is *not* stored here: it uses `SMAppService`, and the system's state is the source of truth.
The same folder holds `state.json` (`cleanShutdown`, `runningIds`), which Wickbar uses for crash recovery.

## MCP (let agents control Wickbar)

Wickbar runs an MCP server using the **Streamable HTTP** transport with JSON responses:

```
POST http://127.0.0.1:9425/mcp
```

It listens on `127.0.0.1` only. It rejects requests whose `Origin` isn't localhost, and checks the `Host`
header to protect against DNS rebinding.

### Claude Code

```sh
claude mcp add --transport http wickbar http://127.0.0.1:9425/mcp
```

### Hermes

In Hermes' `config.yaml`:

```yaml
mcp_servers:
  wickbar:
    url: http://127.0.0.1:9425/mcp
```

### Generic clients (Cursor, Claude Desktop via a bridge, etc.)

```json
{
  "mcpServers": {
    "wickbar": { "type": "http", "url": "http://127.0.0.1:9425/mcp" }
  }
}
```

### Tools

A command can be referred to by its `id` or by its name (exact or case-insensitive), passed as the `command` argument.

| Tool | Arguments | What it does |
| --- | --- | --- |
| `list_commands` | none | All commands with their config and live status (`status`, `pid`, `uptime_seconds`, `last_exit_code`, `restart_count`) |
| `get_command` | `command` | One command's config and status |
| `add_command` | `name`, `command`, `working_directory?`, `environment?`, `auto_start?`, `restart_policy?`, `start_now?` | Save a new command, optionally start it |
| `update_command` | `command`, `name?`, `command_line?`, `working_directory?`, `environment?`, `auto_start?`, `restart_policy?` | Change a command; restarts it if it's running and its command line, directory or environment changed (the result says so) |
| `remove_command` | `command` | Stop and delete a command |
| `start_command` / `stop_command` / `restart_command` | `command` | Control one command (`stop_command` returns once it has stopped) |
| `start_all` / `stop_all` | none | Control everything |
| `get_logs` | `command`, `lines?` (default 200, max 5000) | Recent output as plain text, with ANSI escapes stripped |
| `send_input` | `command`, `text`, `press_enter?` (default true) | Type into the command's terminal |
| `get_settings` | none | Settings, launch-at-login status, config path |
| `update_settings` | `auto_start_on_launch?`, `launch_at_login?`, `restore_after_crash?` | Change settings |

Tool failures (for example an unknown command name) come back as a normal result with `isError: true` and an
explanatory message.

Quick check with curl:

```sh
curl -s http://127.0.0.1:9425/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_commands","arguments":{}}}'
```

## Project layout

```
Package.swift            SwiftPM: WickbarCore (library), Wickbar (app), WickbarTests
VERSION
Sources/WickbarCore/     Pure logic, unit-tested: config model & store, runtime state, output buffer + ANSI
                         stripping, JSON value, HTTP parser/server (Network.framework), MCP server & tools
Sources/Wickbar/
  App/                   SwiftUI app (MenuBarExtra + Window + Settings), AppDelegate (quit handling)
  Runtime/               ShellEnvironment, ManagedProcess (PTY via SwiftTerm LocalProcess), ProcessManager, ProcessTree
  UI/                    Menu bar popover, main window, detail + terminal pane, editor, settings
  System/                Launch at login (SMAppService), notifications
Tests/WickbarTests/      Output buffer / ANSI, config round-trip, HTTP parsing, JSON-RPC/MCP dispatch, command lookup
scripts/build-app.sh     Release build, .app assembly, icon generation, signing (ad-hoc or SIGN_IDENTITY)
scripts/package-release.sh  Developer ID sign + notarize + staple + zip (used by the release workflow)
scripts/make-icon.swift  Draws the app icon (flame on a warm rounded square)
.github/workflows/       CI (build + test on every push/PR) and Release (signed, notarized draft release on v* tags)
```

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as
described in [SECURITY.md](SECURITY.md). Changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).
