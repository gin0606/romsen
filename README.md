# romsen

[日本語](README.ja.md)

Prints what the Slack desktop app is showing as text for an agent, read through the macOS
Accessibility API. Named after ROM専: reads, never posts.

```
swift build -c release
.build/release/romsen slack --help
```

The launching app (terminal or agent host) needs the Accessibility permission.

## Compare output from the same screen

Save the initial accessibility tree as JSON, then replay it with either build:

```sh
.build/debug/romsen slack --save-snapshot /tmp/screen.json
.build/debug/romsen slack --from-snapshot /tmp/screen.json --last 10
```

Replay does not access Slack or need Accessibility permission. It supports the same options,
including `--raw`, but cannot scroll or open threads. Reads are limited to the saved messages;
a missing search or link target fails. Thread links need the requested thread already open,
with its start captured. The saved file contains Slack content: keep it private, do not commit
it, and delete it and any captured output after comparing.

## Current direction

Working assumptions, not fixed rules.

- **Slack only.** Keeping one output format across chat apps looked hard.
- **Shows the agent what the person is looking at.** It scrolls that view to read more, and
  does not switch conversations or workspaces.
- **Read-only.** It scrolls and opens threads. It never types or presses anything that could
  send or change a message.
