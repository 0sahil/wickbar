# Contributing to Wickbar

Thanks for your interest! Bug reports, ideas and pull requests are all welcome.

## Before you start
- For anything bigger than a small fix, please open an issue first so we can agree on the approach.
- Check existing issues to avoid duplicates.

## Development setup
Requirements: macOS 14+, Xcode with Swift 6.2 or newer (SwiftTerm requires it).

```sh
git clone https://github.com/0sahil/wickbar.git
cd wickbar
swift build                 # debug build
swift test                  # unit tests
scripts/build-app.sh        # build/Wickbar.app (ad-hoc signed)
open build/Wickbar.app
```

Tip: quit any installed copy of Wickbar first. Two copies would fight over the MCP port (9425)
and share the same config file in `~/Library/Application Support/Wickbar/`.

## Project layout
- `Sources/WickbarCore/` — pure logic with no AppKit (config, output buffer, HTTP/MCP server). Put testable logic here.
- `Sources/Wickbar/` — the SwiftUI/AppKit app (process runtime, UI, system integrations).
- `Tests/WickbarTests/` — unit tests for WickbarCore.

## Pull requests
- Keep PRs focused; one change per PR.
- Add or update tests for logic changes in `WickbarCore`.
- Make sure `swift build`, `swift test` and `scripts/build-app.sh` pass (CI runs all three).
- For UI changes, include a screenshot or short recording.
- Add a line under `## [Unreleased]` in `CHANGELOG.md`.
- New MCP tools need an `inputSchema`, a one-line description, a test, and a row in the README tool table.

## Code style
- Swift 5 language mode, standard Swift API design guidelines.
- Main-actor for anything touching UI or process state; keep `WickbarCore` free of AppKit.
- Prefer clear names over comments; comment the *why* for anything non-obvious (signals, PTYs, run loops).

## License
By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
