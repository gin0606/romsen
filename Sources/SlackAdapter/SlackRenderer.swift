import Foundation

/// Formats interpreted Slack views without reading the accessibility tree.
public enum SlackRenderer {
    public struct Focus: Equatable, Sendable {
        public var row: String
        public var context: Int
        public var wholeThread: Bool

        public init(timestamp: String, context: Int, wholeThread: Bool = false) {
            self.init(row: timestamp, context: context, wholeThread: wholeThread)
        }

        public init(row: String, context: Int, wholeThread: Bool = false) {
            self.row = row
            self.context = context
            self.wholeThread = wholeThread
        }

        func matches(_ message: SlackMessage) -> Bool {
            message.rowID == row || message.timestamp == row
        }
    }

    public static func render(
        _ screens: [SlackScreen], focus: Focus? = nil, only: SlackHistory.Pane? = nil, timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        for screen in screens {
            lines.append("# Slack" + (screen.workspace.map { ": \($0)" } ?? ""))
            for view in screen.views {
                var rows = view.messages
                if let only, view.kind != (only == .thread ? .thread : .conversation) { continue }
                if let focus {
                    guard let index = rows.firstIndex(where: focus.matches) else { continue }
                    if !(focus.wholeThread && view.kind == .thread) {
                        let context = min(focus.context, rows.count)
                        rows = Array(rows[max(index - context, 0)...min(index + context, rows.count - 1)])
                    }
                }
                lines.append("")
                lines.append("## " + (view.title ?? "(untitled view)"))
                lines.append(contentsOf: view.searchSummary)
                if rows.isEmpty {
                    lines.append(contentsOf: view.plainText)
                } else {
                    lines.append(contentsOf: messages(rows, focus: focus, timeZone: timeZone))
                    if focus == nil, let draft = view.draft {
                        lines.append("")
                        lines.append("draft in composer: \(draft)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func messages(_ rows: [SlackMessage], focus: Focus?, timeZone: TimeZone) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        var lastSender: String?
        for message in rows {
            // Resolve omitted senders after filtering, using only the rows being printed.
            let sender = message.sender ?? lastSender ?? message.labelledSender ?? "?"
            lastSender = sender
            let time = message.sentDate.map(formatter.string(from:)) ?? message.timeLabel ?? "?"
            let body = tidy(body(message.body)).replacingOccurrences(of: "\n", with: "\n  ")
            let marker = focus?.matches(message) == true ? ">> " : ""
            let header = tidy(Self.body(message.location)).replacingOccurrences(of: "\n", with: " ")
            let location = header.isEmpty ? "" : " (\(header))"
            lines.append("\(marker)[\(time)] \(sender)\(location): \(body)")
            if !message.reactions.isEmpty {
                lines.append("  reactions: " + message.reactions.joined(separator: ", "))
            }
            if let replies = message.replies { lines.append("  thread: \(replies)") }
        }
        return lines
    }

    private static func body(_ blocks: [SlackMessage.Block]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let inline):
                return inline.map { piece in
                    switch piece {
                    case .text(let text): return text
                    case .button(let title), .threadOrigin(let title): return "[\(title)]"
                    }
                }.joined()
            case .quote(let quoted):
                return tidy(body(quoted)).split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
            case .file(let name): return "[file: \(name)]"
            }
        }.joined(separator: "\n")
    }

    private static func tidy(_ body: String) -> String {
        body.split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
