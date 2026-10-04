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

## Agent plugin (Codex / Claude Code)

The plugin provides one shared `slack` skill for reading the open conversation,
message links, recent messages, text matches, and whole threads. Install the CLI
with [Homebrew](#install) first; the plugin does not bundle romsen. Make sure
`command -v romsen` works in the agent's shell, grant the launching app
[Accessibility permission](#accessibility-permission), and open the intended
conversation in the Slack desktop app. Reads may scroll or open a thread, but do
not send messages or switch conversations. The skill reports incomplete reads
when romsen warns on stderr.

Get this repository, or use an existing checkout containing `plugins/romsen/`:

```sh
git clone https://github.com/gin0606/romsen.git
cd romsen
```

Run the installation commands below from this directory. Keep the checkout for
local marketplace updates. The installed skill calls `romsen` on PATH, so agent
sessions can run from other working directories.

### Codex

```sh
codex plugin marketplace add .
codex plugin add romsen@romsen
```

Start a new Codex session. Installation enables the plugin; if it was disabled,
set `enabled = true` under `[plugins."romsen@romsen"]` in `~/.codex/config.toml`.
Invoke the skill with `$romsen:slack Read what is currently visible in Slack`.

### Claude Code

```sh
claude plugin marketplace add "$(pwd)"
claude plugin install romsen@romsen --scope user
claude plugin list
```

Check that `romsen@romsen` is enabled (use `claude plugin enable romsen@romsen` if
needed), then start a new session and enter
`/romsen:slack Read what is currently visible in Slack`.
`claude plugin details romsen` lists the shared `slack` skill.

### Validate local changes

The host manifests in `plugins/romsen/` both load `skills/slack/SKILL.md`.
Validate the Claude Code package and marketplace with:

```sh
claude plugin validate ./plugins/romsen --strict
claude plugin validate . --strict
```

For Codex, repeat the local marketplace installation and check the skill in a new
session; its plugin CLI has no standalone validator. For either host, test a read
from outside this repository. Record only the host, version, installation route,
and success/failure; keep actual Slack content and links out of validation records.
Packaging references: [Codex](https://developers.openai.com/plugins/build/plugins)
and [Claude Code](https://code.claude.com/docs/en/plugin-marketplaces).

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

Warnings and fallback text follow the requested pane and message range. A link reads only the
thread when it points into a thread or `--thread` is given, and only the conversation otherwise,
even when another pane shows the same message, such as the root of an open thread. If a filtered
read such as `--last` or a conversation link finds its messages but cannot identify the view that
holds them, it omits unidentified text and warns instead of substituting another pane. A link
still fails when its message or thread cannot be found. Empty known conversations or search
results, omitted senders or times, and date dividers do not by themselves trigger a warning.

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
