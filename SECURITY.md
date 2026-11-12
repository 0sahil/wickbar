# Security policy

## What Wickbar can do
Wickbar runs arbitrary shell commands as your user. Its MCP server lets local programs
(AI agents, scripts) add and run commands. Treat access to it like access to your terminal.

Built-in protections:
- The MCP server listens on `127.0.0.1` only; it is not reachable from other machines.
- Requests with a non-localhost `Origin` header are rejected (stops websites in your browser from calling it).
- The `Host` header is checked to block DNS-rebinding attacks.
- You can turn the MCP server off in *Settings › MCP*.

Not protected against: other software already running on your Mac as your user. Such software
could already run commands directly, so Wickbar does not add a token on top.

## Reporting a vulnerability
Please **do not** open a public issue. Use GitHub's private
[security advisory form](https://github.com/0sahil/wickbar/security/advisories/new) instead.
You'll get a response within a few days. Please include steps to reproduce and the Wickbar version.

## Supported versions
Only the latest release receives security fixes.
