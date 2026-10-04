import Foundation

/// Formats interpreted Slack views without reading the accessibility tree.
package enum SlackRenderer {
    package struct Focus: Equatable, Sendable {
        package var row: String
        package var context: Int
        package var wholeThread: Bool

        package init(timestamp: String, context: Int, wholeThread: Bool = false) {
            self.init(row: timestamp, context: context, wholeThread: wholeThread)
        }

        package init(row: String, context: Int, wholeThread: Bool = false) {
            self.row = row
            self.context = context
            self.wholeThread = wholeThread
        }

        func matches(_ message: SlackMessage) -> Bool {
            message.rowID == row || message.timestamp == row
        }
    }

    package static func render(
        _ screens: [SlackScreen], focus: Focus? = nil, only: SlackHistory.Pane? = nil,
        last: Int? = nil, timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        for screen in screens {
            lines.append("# Slack" + (screen.workspace.map { ": \($0)" } ?? ""))
            for view in screen.views {
                guard view.matches(only: only), let rows = view.selectedMessages(focus: focus, last: last) else { continue }
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
            if message.isFallback, let fallback = message.fallbackText {
                lines.append(contentsOf: fallback)
                continue
            }
            // Resolve omitted senders after filtering, using only the rows being printed.
            let sender = message.sender ?? lastSender ?? message.labelledSender ?? "?"
            lastSender = sender
            let time = message.sentDate.map(formatter.string(from:)) ?? message.timeLabel ?? "?"
            let body = body(message.body).replacingOccurrences(of: "\n", with: "\n  ")
            let marker = focus?.matches(message) == true ? ">> " : ""
            let header = Self.body(message.location).replacingOccurrences(of: "\n", with: " ")
            let location = header.isEmpty ? "" : " (\(header))"
            lines.append("\(marker)[\(time)] \(sender)\(location): \(body)")
            if !message.reactions.isEmpty {
                lines.append("  reactions: " + message.reactions.joined(separator: ", "))
            }
            if let replies = message.replies { lines.append("  thread: \(replies)") }
            lines.append(contentsOf: message.fallbackText ?? [])
        }
        return lines
    }

    private static func body(_ blocks: [SlackMessage.Block]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let inline):
                return paragraph(inline)
            case .quote(let quoted):
                return body(quoted).components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            case .file(let name): return "[file: \(name)]"
            }
        }.joined(separator: "\n")
    }

    private static func paragraph(_ pieces: [SlackMessage.Inline]) -> String {
        var output = ""
        var space = false
        func prose(_ text: String) {
            for character in text {
                if character == " " {
                    space = !output.isEmpty && output.last != "\n"
                } else if character == "\n" {
                    space = false
                    if !output.isEmpty && output.last != "\n" { output.append(character) }
                } else {
                    if space { output.append(" "); space = false }
                    output.append(character)
                }
            }
        }
        for piece in pieces {
            switch piece {
            case .text(let text): prose(text)
            case .button(let title), .threadOrigin(let title): prose("[\(title)]")
            case .code(let text):
                if space { output.append(" "); space = false }
                output += code(text)
            }
        }
        while output.last == "\n" { output.removeLast() }
        return output
    }

    private static func code(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        if text.contains("\n") {
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return "\(fence)\n\(text)\n\(fence)"
        }
        let fence = String(repeating: "`", count: longest + 1)
        let edgeSpace = (text.first == " " || text.last == " ") && !text.allSatisfy { $0 == " " }
        let padding = text.first == "`" || text.last == "`" || edgeSpace ? " " : ""
        return "\(fence)\(padding)\(text)\(padding)\(fence)"
    }
}
