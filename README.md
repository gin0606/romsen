# romsen

[日本語](README.ja.md)

Prints what the Slack desktop app is showing as text for an agent, read through the macOS
Accessibility API. Named after ROM専: reads, never posts.

```
swift build -c release
.build/release/romsen slack --help
```

The launching app (terminal or agent host) needs the Accessibility permission.

## Current direction

Working assumptions, not fixed rules.

- **Slack only.** Keeping one output format across chat apps looked hard.
- **Shows the agent what the person is looking at.** It scrolls that view to read more, and
  does not switch conversations or workspaces.
- **Read-only.** It scrolls and opens threads. It never types or presses anything that could
  send or change a message.
