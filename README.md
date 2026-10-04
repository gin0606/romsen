# romsen

[日本語](README.ja.md)

Prints what Slack or Google Chrome is showing as text for an agent, read through the macOS
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

romsen reads Slack and Chrome through the macOS Accessibility API. The permission belongs to the app that
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

Install from the Git marketplace below; no local checkout is needed. The skill
calls `romsen` on PATH, so agent sessions can run from any working directory.
Plugin updates follow this repository's default branch (`main`), independently
of Homebrew CLI releases.

### Codex

```sh
codex plugin marketplace add gin0606/romsen
codex plugin add romsen@romsen
```

Start a new Codex session. Installation enables the plugin; if it was disabled,
set `enabled = true` under `[plugins."romsen@romsen"]` in `~/.codex/config.toml`.
Invoke the skill with `$romsen:slack Read what is currently visible in Slack`.

In Codex CLI 0.160.0, starting a session refreshes Git marketplaces and installed
plugins in the background; the updated skill is available in the next session.
This automatic refresh was verified on that version and is not documented as a
guarantee for every Codex host or version.

### Claude Code

If you previously registered `romsen` from a local checkout, first run
`claude plugin marketplace remove romsen --scope user`, then install from Git:

```sh
claude plugin marketplace add gin0606/romsen
claude plugin install romsen@romsen --scope user
claude plugin list
```

Check that `romsen@romsen` is enabled (use `claude plugin enable romsen@romsen` if
needed), then start a new session and enter
`/romsen:slack Read what is currently visible in Slack`.
`claude plugin details romsen` lists the shared `slack` skill.

In `/plugin`, open **Marketplaces**, select **romsen**, and choose
**Enable auto-update**. Third-party marketplaces have auto-update disabled by
default. Updates run in the background after the first message in an interactive
session, with a delay of up to ten minutes. Use the updated skill in the next
session, or run `/reload-plugins` after the update completes. See
[Claude Code's loading reference](https://code.claude.com/docs/en/plugins/loading#when-auto-update-runs).

### Validate local changes

Clone this repository and run these commands from its root. Local marketplaces
are for developing the skill; they do not fetch changes from GitHub:

```sh
codex plugin marketplace add .
codex plugin add romsen@romsen
claude plugin marketplace add "$(pwd)"
claude plugin install romsen@romsen --scope user
```

Use an isolated host configuration if `romsen` is already registered as a Git
marketplace. The host manifests in `plugins/romsen/` both load `skills/slack/SKILL.md`.
After changing tracked plugin files, regenerate both host versions before committing
(stage new plugin files first). Python 3 and Git are required:

```sh
scripts/plugin-version
scripts/plugin-version --check
```

Both manifests use the same `0.1.0+plugin.<hash>` version. The hash covers the paths
and contents of Git-tracked files in `plugins/romsen/`, excluding the generated
`version` field in both manifests. CI rejects either manifest if its value is stale.
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

## Read Chrome

```sh
romsen chrome
romsen chrome --all
romsen chrome --raw
```

Reads the selected tab in Chrome's focused window and prints its title, URL and structured text.
By default, reads declared main regions and open dialogs, excluding surrounding navigation and
sidebars. Supplementary content inside main regions is retained. Without a declared main region,
it removes recognised navigation, sidebars, banners, footers and search regions and keeps other
content. Unlabelled sidebars may remain. `--all` reads the whole page, including those regions.

Headings, paragraphs, links and nested lists retain their relationships. Tables preserve column
alignment; merged or sparse cells have explicit positions and spans. Controls include their
labels, values and available states, such as checked, selected or disabled. Main content,
navigation, forms, dialogs and other declared regions have explicit boundaries.

Clearly separated sibling blocks in a single vertical stack follow their on-screen order.
Nearby inline text wrappers stay within the sentence. Columns, overlapping or clipped elements,
and elements without usable coordinates retain accessibility order; headings, table rows and
numbered list items are not reordered by these layout corrections.

Browser toolbars are excluded. The command does not scroll, switch tabs, or bring Chrome forward.
Accessibility may expose text outside the viewport and omit content such as text drawn on a
canvas. Layout and regions without semantic labels cannot always be reconstructed. The output
is not a screenshot or a full HTML export, and does not include unseen or unloaded content.

`--save-snapshot /tmp/page.json` and `--from-snapshot /tmp/page.json` save and replay the focused
window, just like Slack snapshots. Keep these files and captured output private and delete them
after use. `--raw` includes the browser controls in that window. Older snapshots still work,
but missing link destinations or control states cannot be recovered from them.

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

If two or more Slack windows contain conversation or thread views, a message link, `--last`,
`--find`, `--thread`, or `--history` greater than 0 fails with exit code 1 before scrolling or
clicking. Keep only one window showing the conversation or thread you want to read. Windows
without these views do not count. With no options, all windows are printed with headings;
`--raw` and `--save-snapshot` still include all windows. Live reads and `--from-snapshot`
use the same check, even when the windows show the same conversation.

Accessibility acquisition failures, traversal limits and Chromium readiness timeouts fail the
command instead of returning a partial snapshot as a successful read. This also applies to
`--raw` and `--save-snapshot`.

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

- **Slack and Chrome.** Slack reads conversations; Chrome reads the selected page as text.
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
