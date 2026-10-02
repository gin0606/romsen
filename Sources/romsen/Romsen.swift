import ArgumentParser
import AXSnapshot
import Foundation
import SlackAdapter

@main
struct Romsen: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the messages a chat app is currently showing, as text for an agent to read.",
        discussion: "Read-only: it scrolls the message list and opens threads when asked to, and never types.",
        subcommands: [Slack.self]
    )
}

struct Slack: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the messages in the conversation open in Slack.",
        discussion: """
            With no options, prints what Slack has on screen without touching it. The options below \
            scroll the message list as far as they need to, then scroll it back.

            A message link prints that message and its neighbours. The conversation it points to \
            must already be open in Slack. A link into a thread opens that thread.
            """
    )

    @Argument(help: "A Slack message link (https://<workspace>.slack.com/archives/<channel>/p<timestamp>).")
    var link: String?

    @Option(help: "Print only the newest <last> messages, reading further back if fewer are on screen.")
    var last: Int?

    @Option(help: "Print the newest message containing this text, and its neighbours.")
    var find: String?

    @Option(help: "With a link or --find, how many messages to print before and after the matched one.")
    var context = 5

    @Option(help: "Scroll up this many extra times to include older messages.")
    var history = 0

    @Flag(
        help: """
            Read the thread instead of the conversation. Alone, prints the whole open thread. With a \
            link, opens the linked message's thread and prints all of it.
            """)
    var thread = false

    @Flag(help: "Print the unprocessed accessibility tree instead of the messages.")
    var raw = false

    func validate() throws {
        if link != nil, last != nil || find != nil {
            throw ValidationError("A link cannot be combined with --last or --find.")
        }
        if last != nil, find != nil {
            throw ValidationError("--last and --find cannot be combined.")
        }
        if let last, last < 1 { throw ValidationError("--last must be at least 1.") }
        if context < 0 || history < 0 { throw ValidationError("--context and --history cannot be negative.") }
    }

    func run() throws {
        let bundleID = SlackInterpreter.bundleID
        let driver = SlackHistory.Driver(
            snapshot: { try Reader.snapshotWindows(bundleID: bundleID) },
            scrollToVisible: { Reader.scrollToVisible(bundleID: bundleID, domID: $0) },
            pause: { Thread.sleep(forTimeInterval: 0.3) },
            press: { Reader.press(bundleID: bundleID, domID: $0, descendantClass: $1) })

        do {
            let options = try SlackRead.Options(link: link, last: last, find: find, context: context, history: history, thread: thread)
            let current = try driver.snapshot()
            if raw {
                print(current.map { $0.outline() }.joined(separator: "\n"))
                return
            }

            let request: SlackHistory.Request
            switch try SlackRead.prepare(options, in: current) {
            case .read(let planned):
                request = planned
            case let .openThread(root, planned):
                let opened = try SlackHistory.openThread(root: root, driver: driver)
                let after = opened ? [] : try driver.snapshot()
                try SlackRead.afterOpeningThread(root: root, opened: opened, in: after)
                request = planned
            }
            let windows = try SlackHistory.collect(request, driver: driver)
            let output = try SlackRead.output(options, request: request, in: windows)
            print(SlackRenderer.render(SlackInterpreter.read(windows), focus: output.focus, only: output.only))
        } catch let error as SlackRead.Failure {
            throw fail(error.description)
        } catch let error as ReaderError {
            throw fail(error.description)
        }
    }

    private func fail(_ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("romsen: \(message)\n".utf8))
        return ExitCode.failure
    }
}
