import ArgumentParser
import AXSnapshot
import AXTree
import Foundation
import SlackAdapter

public struct Slack: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        abstract: "Print the messages in the conversation open in Slack.",
        discussion: """
            With no options, prints what Slack has on screen without touching it. The options below \
            scroll the message list as far as they need to, then scroll it back.

            A message link prints that message and its neighbours, or the whole thread with \
            --thread. It reads only the thread for a link into a thread or with --thread, and only \
            the conversation otherwise. The conversation must already be open in Slack. A link into \
            a thread opens that thread.

            --save-snapshot saves the initial screen as JSON before any scrolling or clicks, while \
            printing the usual output. --from-snapshot reads that JSON without accessing Slack or \
            needing Accessibility permission. Scrolling and clicks fail without being performed: \
            --last returns at most the saved messages, --history cannot add messages, and --find \
            or a link fails if its target is missing. Thread links require the requested thread \
            to be open with its start captured; --thread alone reads the saved open thread.

            Unrecognised view structure or timestamp-shaped message rows produce a warning on \
            stderr; available text stays on stdout and warnings alone exit 0. Filtered reads, \
            including conversation links, omit text whose view cannot be identified instead of \
            using another pane. Existing errors still fail, including a link whose message or \
            thread is missing. Empty known views and omitted sender/time fields do not trigger \
            warnings. This detects known structural mismatches, not every missing field or change \
            that removes all row clues. The same checks apply to live and saved reads; --raw does \
            not warn about structure.

            Example: romsen slack --save-snapshot /tmp/screen.json
                     romsen slack --from-snapshot /tmp/screen.json --last 10
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

    @Option(help: "Save the initial accessibility tree as JSON to this file. Contains Slack content; keep it private.")
    var saveSnapshot: String?

    @Option(help: "Read a saved JSON tree instead of Slack. Scrolls and clicks are disabled.")
    var fromSnapshot: String?

    public func validate() throws {
        if link != nil, last != nil || find != nil {
            throw ValidationError("A link cannot be combined with --last or --find.")
        }
        if last != nil, find != nil {
            throw ValidationError("--last and --find cannot be combined.")
        }
        if let last, last < 1 { throw ValidationError("--last must be at least 1.") }
        if context < 0 || history < 0 { throw ValidationError("--context and --history cannot be negative.") }
    }

    func makeDriver() throws -> SlackHistory.Driver {
        if let fromSnapshot {
            let windows: [Node]
            do {
                windows = try JSONDecoder().decode([Node].self, from: Data(contentsOf: URL(fileURLWithPath: fromSnapshot)))
            } catch {
                throw ValidationError("could not read snapshot at \(fromSnapshot): \(error.localizedDescription)")
            }
            return SlackHistory.Driver(snapshot: { windows }, scrollToVisible: { _ in false },
                                       pause: {}, press: { _, _ in false }, source: .saved)
        }
        let bundleID = SlackInterpreter.bundleID
        return SlackHistory.Driver(
            snapshot: { try Reader.snapshotWindows(bundleID: bundleID, preparation: .chromium()) },
            scrollToVisible: { Reader.scrollToVisible(bundleID: bundleID, domID: $0) },
            pause: { Thread.sleep(forTimeInterval: 0.3) },
            press: { Reader.press(bundleID: bundleID, domID: $0, descendantClass: $1) })
    }

    func read(using driver: SlackHistory.Driver, warn: (String) -> Void = { _ in }) throws -> String {
        let options = try SlackRead.Options(link: link, last: last, find: find, context: context, history: history, thread: thread)
        let current = try driver.snapshot()
        if let saveSnapshot {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(current).write(to: URL(fileURLWithPath: saveSnapshot), options: .atomic)
            } catch {
                throw ValidationError("could not save snapshot at \(saveSnapshot): \(error.localizedDescription)")
            }
        }
        if raw {
            return current.map { $0.outline() }.joined(separator: "\n")
        }

        let request: SlackHistory.Request
        var initial: [Node]? = current
        var threadReads: [[Node]] = []
        switch try SlackRead.prepare(options, in: current) {
        case .read(let planned):
            request = planned
        case let .openThread(root, planned):
            let opening = SlackRead.openingThread(root: root, in: current, source: driver.source)
            let opened = opening.press
                ? try SlackHistory.openThread(root: root, driver: driver, onThreadRead: { threadReads.append($0) })
                : opening.alreadyOpen
            let after = !opened && opening.rereadIfUnconfirmed ? try driver.snapshot() : []
            try SlackRead.afterOpeningThread(root: root, opened: opened, in: after)
            request = planned
            if opening.startFromThreadRead { initial = threadReads.last }
        }
        let windows = try SlackHistory.collect(request, driver: driver, initial: initial, observations: threadReads)
        let output = try SlackRead.output(options, request: request, in: windows)
        let screens = SlackInterpreter.read(windows)
        for diagnostic in SlackInterpreter.diagnostics(screens, focus: output.focus, only: output.only, last: output.last) {
            warn(diagnostic.rawValue)
        }
        return SlackRenderer.render(screens, focus: output.focus, only: output.only, last: output.last)
    }

    public func run() throws {
        do {
            print(try read(using: makeDriver(), warn: { message in
                FileHandle.standardError.write(Data("romsen: warning: \(message)\n".utf8))
            }))
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
