# Changelog

All notable changes to Wickbar are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-12

First public release.

### Added
- Menu-bar app (no Dock icon) with a main window and Settings.
- Saved commands that run in a real PTY, with a live terminal view (colors, input, Ctrl-C) and ~2 MB of scrollback kept while the window is closed.
- Start / stop / restart per command, plus start all / stop all. Stopping kills the whole process tree (SIGTERM, then SIGKILL after 5 s).
- Restart policies (`never`, `onFailure`, `always`) with exponential backoff; gives up and notifies after repeated crashes.
- Launch at login, auto-start commands on launch, and restore of previously running commands after Wickbar itself crashes.
- Login-shell environment capture, so tools from Homebrew, `~/.cargo/bin`, nvm etc. are found.
- Human-editable `config.json`, watched for external edits.
- Built-in MCP server (Streamable HTTP, `127.0.0.1:9425/mcp`) with 14 tools so agents can add, configure, start, stop and read the logs of commands.

[Unreleased]: https://github.com/0sahil/wickbar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/0sahil/wickbar/releases/tag/v0.1.0
