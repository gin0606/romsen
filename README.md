# romsen

[日本語](README.ja.md)

Prints what the Slack desktop app is showing as text for an agent, read through the macOS
Accessibility API. Named after ROM専: reads, never posts.

## Install

```sh
brew install gin0606/tap/romsen
romsen slack --help
```

The Homebrew formula installs a prebuilt binary for macOS 13 or later on Apple silicon.

To build from source instead, run `swift build -c release` and use `.build/release/romsen`.
`romsen --version` prints `0.0.0-dev` unless built by the release workflow.

## Accessibility permission

romsen reads Slack through the macOS Accessibility API. The permission belongs to the app that
launches romsen, such as your terminal or agent host, not to romsen itself. Allow that app in
System Settings > Privacy & Security > Accessibility.

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

## Reading warnings

If a view cannot be recognised, or a timestamp-shaped message row cannot be interpreted,
romsen warns on stderr that output may be incomplete. Available text is kept on stdout,
including unrecognised rows encountered while scrolling. Warnings alone exit with code 0;
permission, read, link and search errors still fail.

Warnings and fallback text follow the requested pane and message range. If a filtered read
such as `--last` cannot identify its pane, it omits unidentified text and warns instead of
substituting another pane. Empty known conversations or search results, omitted senders or
times, and date dividers do not by themselves trigger a warning.

These checks detect known structural mismatches, without attributing them to a Slack update.
They cannot guarantee detection when all message clues disappear or fields inside an otherwise
recognised message go missing. Live reads and `--from-snapshot` use the same checks; `--raw`
prints the unprocessed tree without structural warnings.

## Current direction

Working assumptions, not fixed rules.

- **Slack only.** Keeping one output format across chat apps looked hard.
- **Shows the agent what the person is looking at.** It scrolls that view to read more, and
  does not switch conversations or workspaces.
- **Read-only.** It scrolls and opens threads. It never types or presses anything that could
  send or change a message.

## Release

`scripts/release 1.2.3` runs on a clean `main` that is not behind `origin/main`. It checks that
`v1.2.3` is not on origin yet, runs `swift test`, creates the annotated tag `v1.2.3`, and pushes
`main` and the tag together. The tag starts the release workflow, which tests and builds the
arm64 binary, publishes the GitHub Release, and updates the formula in `gin0606/homebrew-tap`.
A failed run can be re-run for the same tag.

## License

[MIT](LICENSE)
