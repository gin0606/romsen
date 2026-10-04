import ArgumentParser
import RomsenChrome
import RomsenSlack

@main
struct Romsen: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print what Slack or Chrome is currently showing, as text for an agent to read.",
        discussion: "Read-only: Slack can scroll and open threads when asked to. Chrome only reads. It never types.",
        version: romsenVersion,
        subcommands: [Slack.self, Chrome.self]
    )
}
