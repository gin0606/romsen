import ArgumentParser
import RomsenSlack

@main
struct Romsen: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the messages a chat app is currently showing, as text for an agent to read.",
        discussion: "Read-only: it scrolls the message list and opens threads when asked to, and never types.",
        version: romsenVersion,
        subcommands: [Slack.self]
    )
}
