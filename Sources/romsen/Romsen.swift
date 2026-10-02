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
        var target: SlackLink?
        if let link {
            guard let parsed = SlackLink(link) else { throw fail("not a Slack message link: \(link)") }
            target = parsed
        }
        let bundleID = SlackInterpreter.bundleID
        let driver = SlackHistory.Driver(
            snapshot: { try Reader.snapshotWindows(bundleID: bundleID) },
            scrollToVisible: { Reader.scrollToVisible(bundleID: bundleID, domID: $0) },
            pause: { Thread.sleep(forTimeInterval: 0.3) },
            press: { Reader.press(bundleID: bundleID, domID: $0, descendantClass: $1) })

        do {
            let current = try driver.snapshot()
            if raw {
                print(current.map { $0.outline() }.joined(separator: "\n"))
                return
            }

            var request = SlackHistory.Request()
            request.olderPages = history
            request.last = last
            request.containing = find
            if let target {
                // Checked before scrolling, so a link to another conversation never moves the window.
                if let open = SlackInterpreter.openChannelID(current), open != target.channelID {
                    throw fail(
                        "the link points to conversation \(target.channelID), but Slack is showing \(open). "
                            + "Open that conversation in Slack and run this again.")
                }
                if let root = target.threadTimestamp ?? (thread ? target.timestamp : nil) {
                    // A long thread that is already open does not render its first message, so it
                    // cannot be recognised here. Search it anyway and let the lookup below decide.
                    guard try SlackHistory.openThread(root: root, driver: driver)
                        || SlackHistory.hasList(.thread, in: try driver.snapshot())
                    else {
                        throw fail("could not open the thread of message \(root) in the open conversation.")
                    }
                    request.pane = .thread
                }
                request.target = target.timestamp
                request.whole = thread
            } else {
                // Beside search results there is no conversation, so the open thread is what is meant.
                if thread || !SlackHistory.hasList(.conversation, in: current) {
                    if SlackHistory.hasList(.thread, in: current) {
                        request.pane = .thread
                    } else if thread {
                        throw fail("no thread is open in Slack.")
                    }
                }
                request.whole = thread && last == nil && find == nil
            }

            let windows = try SlackHistory.collect(request, driver: driver)
            var focus: SlackRenderer.Focus?
            if let target {
                guard SlackInterpreter.contains(windows, timestamp: target.timestamp) else {
                    throw fail("message \(target.timestamp) was not found in the open conversation.")
                }
                focus = .init(timestamp: target.timestamp, context: context, wholeThread: thread)
            } else if let find {
                let rows = SlackHistory.messageRows(request.pane, in: windows)
                guard let match = rows.last(where: { SlackHistory.contains($0, text: find) })?.domID else {
                    throw fail("no message containing \"\(find)\" was found in the last \(rows.count) messages.")
                }
                focus = .init(row: match, context: context)
            }
            let only = last != nil || (thread && target == nil) ? request.pane : nil
            print(SlackRenderer.render(SlackInterpreter.read(windows), focus: focus, only: only))
        } catch let error as ReaderError {
            throw fail(error.description)
        }
    }

    private func fail(_ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("romsen: \(message)\n".utf8))
        return ExitCode.failure
    }
}
