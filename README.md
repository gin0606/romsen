# romsen

[日本語](README.ja.md)

Reads what Slack or Google Chrome is showing through the macOS Accessibility API and prints text for agents. Named after ROM専: reads, never posts.

## Install

Homebrew builds support macOS 13 or later on Apple silicon.

```sh
brew install gin0606/tap/romsen
```

In System Settings > Privacy & Security > Accessibility, allow the app that launches romsen, such as your terminal or agent host.

## Usage

### Slack

Open the intended conversation in the Slack desktop app, then run:

```sh
romsen slack            # Read the current view
romsen slack --last 10   # Read the latest 10 messages
romsen slack --thread    # Read the whole open thread
```

With no options, the view is left untouched. Options may scroll or open a thread. romsen does not switch conversations or workspaces, or send or edit messages. Message links and text searches are also supported; see `romsen slack --help`.

### Chrome

```sh
romsen chrome           # Read the main content
romsen chrome --all     # Include navigation and sidebars
```

Reads the selected tab in Chrome's focused window and prints its title, URL and structured text, including headings, links, lists and tables. It does not scroll, switch tabs or bring Chrome forward. See `romsen chrome --help` for all options.

## Agent plugin

The plugin provides a `slack` skill. Install the CLI with [Homebrew](#install) and make sure `romsen` is on the agent's PATH.

### Codex

```sh
codex plugin marketplace add gin0606/romsen
codex plugin add romsen@romsen
```

Start a new session and invoke `$romsen:slack Read what is currently visible in Slack`.

### Claude Code

```sh
claude plugin marketplace add gin0606/romsen
claude plugin install romsen@romsen --scope user
```

Start a new session and invoke `/romsen:slack Read what is currently visible in Slack`.

## Limitations and warnings

romsen reads what Accessibility exposes. This can include text outside the viewport and omit content such as text drawn on a canvas. Output is not guaranteed to be complete, even when no warning is reported.

Slack reads that cannot interpret part of the view warn on stderr and keep available text on stdout. Warnings alone exit with code 0; permission and read errors fail.

If a Slack read fails because multiple windows show conversations or threads, keep only one window showing the conversation or thread you want to read and retry.

## Development

[Development guide (Japanese)](DEVELOPMENT.md)

## License

[MIT](LICENSE)
