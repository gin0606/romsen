import AXSnapshot
import Foundation

/// Turns a snapshot of the Slack window into compact text. It keys on the DOM ids and CSS
/// classes Slack exposes through accessibility, and anything it does not recognise falls
/// through as plain text rather than being dropped.
///
/// Ids and classes are used instead of labels because the interface language is set per
/// workspace: one workspace shows "ホーム" where another shows "Home". Classes come in two
/// kinds. Plain ones such as `c-message__sender_button` are matched whole. Ones with a build
/// hash, such as `listitem__iBnNh`, are matched by the part before the hash.
///
/// The output was checked by eye against the app for plain text, mentions, links, inline code,
/// bulleted lists, emoji, reactions, edited marks, shared messages, file attachments, replies
/// also sent to the channel, and search results. Images, code blocks, link previews, and
/// huddles have not been looked at.
public enum SlackRenderer {
    public static let bundleID = "com.tinyspeck.slackmacgap"

    /// Narrows the output to one message and its neighbours.
    public struct Focus: Equatable, Sendable {
        /// The DOM id of the message's row, or just the message timestamp the id ends with.
        public var row: String
        public var context: Int
        /// Print a thread holding the message in full instead of only the neighbours.
        public var wholeThread: Bool

        public init(timestamp: String, context: Int, wholeThread: Bool = false) {
            self.init(row: timestamp, context: context, wholeThread: wholeThread)
        }

        public init(row: String, context: Int, wholeThread: Bool = false) {
            self.row = row
            self.context = context
            self.wholeThread = wholeThread
        }

        func matches(_ node: Node) -> Bool {
            node.domID == row || node.domID?.hasSuffix("_" + row) == true
        }
    }

    /// One section per open message view: the conversation, the thread when one is open, and the
    /// search results when Slack is showing a search.
    /// With a focus, only the views holding that message are printed, and the message is marked `>>`.
    /// With `only`, the other pane and the search results are left out.
    public static func render(
        _ windows: [Node], focus: Focus? = nil, only: SlackHistory.Pane? = nil, timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        for window in windows {
            let workspace = window.first { $0.hasClass("p-client_workspace_wrapper") }?.description
            lines.append("# Slack" + (workspace.map { ": \($0)" } ?? ""))
            for view in window.all(where: { $0.hasClass("p-view_contents") }) {
                var rows = view.all(where: isMessageRow)
                // Slack gives the search results the same class as the channel sidebar.
                if view.hasClass("p-view_contents--sidebar"), rows.isEmpty { continue }
                if let only {
                    let isThread = SlackHistory.isThreadView(view)
                    if isThread != (only == .thread) || (!isThread && !SlackHistory.hasList(.conversation, in: [view])) {
                        continue
                    }
                }
                if let focus {
                    guard let index = rows.firstIndex(where: focus.matches) else { continue }
                    if !(focus.wholeThread && SlackHistory.isThreadView(view)) {
                        let context = min(focus.context, rows.count)
                        rows = Array(rows[max(index - context, 0)...min(index + context, rows.count - 1)])
                    }
                }
                lines.append("")
                lines.append("## " + (view.description ?? "(untitled view)"))
                lines.append(contentsOf: searchSummary(view))
                if rows.isEmpty {
                    lines.append(contentsOf: plainText(view))
                } else {
                    lines.append(contentsOf: messages(rows, focus: focus, timeZone: timeZone))
                    if focus == nil, let draft = draft(in: view) {
                        lines.append("")
                        lines.append("draft in composer: \(draft)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func contains(_ windows: [Node], timestamp: String) -> Bool {
        SlackHistory.contains(windows, timestamp: timestamp)
    }

    /// The id of the conversation whose messages are on screen, if Slack exposes it. The date
    /// dividers in the message list carry it: `message-list_<milliseconds>.<conversation id>`.
    public static func openChannelID(_ windows: [Node]) -> String? {
        for window in windows {
            guard let list = window.first(where: SlackHistory.isMessageList) else { continue }
            for row in list.children {
                guard let id = row.domID, id.hasPrefix(SlackHistory.rowIDPrefix),
                    let suffix = id.split(separator: ".").last, suffix.first?.isLetter == true
                else { continue }
                return String(suffix)
            }
        }
        return nil
    }

    // MARK: Messages

    /// Rows in a conversation, a thread, and the search results all wrap this element.
    private static func isMessageRow(_ node: Node) -> Bool {
        node.children.contains { $0.hasClass("c-message_kit__hover") }
    }

    /// The query and result count shown above search results. Empty for other views.
    /// Search result rows have a random id rather than a message timestamp, so their time is
    /// printed as Slack words it ("9月15日 16:00"), without a year.
    private static func searchSummary(_ view: Node) -> [String] {
        func text(classPrefix: String) -> String? {
            view.first { $0.domClasses.contains { $0.hasPrefix(classPrefix) } }
                .map { $0.children.filter { $0.role == "AXStaticText" }.compactMap(\.value).joined() }
        }
        return [text(classPrefix: "headerContainer__"), text(classPrefix: "resultCounts__")]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func messages(_ rows: [Node], focus: Focus?, timeZone: TimeZone) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        var lastSender: String?
        for row in rows {
            var message = Message()
            message.read(row)
            // Slack omits the sender on consecutive messages from the same person. When the first
            // row on screen is such a message, its label ("<sender> : <text>") still names them.
            // Only some rows carry a label, and its wording was seen in Japanese only.
            let labelled = row.title?.range(of: " : ").map { String(row.title![..<$0.lowerBound]) }
            let sender = message.sender ?? lastSender ?? labelled ?? "?"
            lastSender = sender
            let time = sentDate(of: row).map(formatter.string(from:)) ?? message.timeLabel ?? "?"
            let body = tidy(message.body).replacingOccurrences(of: "\n", with: "\n  ")
            let marker = focus?.matches(row) == true ? ">> " : ""
            let location = message.location.map { " (\($0))" } ?? ""
            lines.append("\(marker)[\(time)] \(sender)\(location): \(body)")
            if !message.reactions.isEmpty {
                lines.append("  reactions: " + message.reactions.joined(separator: ", "))
            }
            if let replies = message.replies {
                lines.append("  thread: \(replies)")
            }
        }
        return lines
    }

    private static func draft(in view: Node) -> String? {
        let text = view.first { $0.role == "AXTextArea" && $0.hasClass("ql-editor") }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// Collapses runs of spaces and drops blank lines.
    private static func tidy(_ body: String) -> String {
        body.split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Message rows carry Slack's message timestamp in their DOM id: `message-list_<seconds>.<micros>`.
    private static func sentDate(of row: Node) -> Date? {
        guard let id = row.domID, let separator = id.lastIndex(of: "_") else { return nil }
        let parts = id[id.index(after: separator)...].split(separator: ".")
        guard parts.count == 2, let seconds = TimeInterval(parts[0]), parts[1].allSatisfy(\.isNumber) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private struct Message {
        var sender: String?
        var timeLabel: String?
        /// Where the message was posted, which search results show between the sender and the time.
        var location: String?
        var body = ""
        var replies: String?
        var reactions: [String] = []
        /// The last inline piece added to the body, which decides what separates it from the next.
        private var previous: Node?
        private var paragraphRightEdge: CGFloat?
        private var justReadSender = false

        /// Controls Slack draws on a message that are not part of what was said: the "view thread"
        /// hint, the "see new replies" button, the hover toolbar with its quick-reaction emoji
        /// (present in the tree whether or not the pointer is over the message), and the file
        /// type heading above an attachment.
        private static let chrome = [
            "c-message__reply_bar_description", "c-message__broadcast_footer", "c-message_actions__container",
            "c-message_kit__file",
        ]

        mutating func read(_ node: Node) {
            let followsSender = justReadSender
            justReadSender = false
            if node.hasClass("c-message__sender_button") {
                sender = node.title
                justReadSender = true
            } else if followsSender, node.role == "AXImage" {
                return  // The sender's status emoji.
            } else if node.hasClass("c-timestamp") {
                timeLabel = node.description?.trimmingCharacters(in: .whitespaces)
                let header = SlackRenderer.tidy(body).replacingOccurrences(of: "\n", with: " ")
                location = header.isEmpty ? nil : header
                body = ""
                previous = nil
            } else if node.hasClass("c-message__reply_count") {
                replies = node.title
            } else if Message.chrome.contains(where: node.hasClass) {
                return
            } else if node.hasClass("c-reaction_bar") {
                for reaction in node.all(where: { $0.hasClass("c-reaction") }) {
                    let emoji = reaction.first { $0.role == "AXImage" }.flatMap(emojiName) ?? "?"
                    let count = reaction.first { $0.role == "AXStaticText" }?.value ?? "1"
                    reactions.append("\(emoji) \(count)")
                }
            } else if node.hasClass("c-message_attachment") {
                // A message shared from elsewhere: quote it so it is not read as the sender's words.
                var quoted = Message()
                for child in node.children { quoted.read(child) }
                let lines = SlackRenderer.tidy(quoted.body).split(separator: "\n").map { "> \($0)" }
                appendBlock(lines.joined(separator: "\n"))
            } else if node.hasClass("c-pillow_file_container") {
                appendBlock("[file: \(node.description ?? SlackRenderer.plainText(node).joined(separator: " "))]")
            } else if node.hasClass("c-message__broadcast_preamble_link") {
                // The start of the thread this reply was also sent to the channel from.
                body += " [\(node.title ?? "")]\n"
                previous = nil
            } else if node.hasClass("c-mrkdwn__code") {
                append("`\(SlackRenderer.plainText(node).joined())`", from: node)
            } else if node.role == "AXStaticText" {
                let value = node.value ?? ""
                if value.allSatisfy(\.isWhitespace) {
                    body += " "
                } else {
                    append(value, from: node)
                }
            } else if node.role == "AXImage" {
                if let name = emojiName(node) { append(name, from: node) }
            } else if node.role == "AXLink" {
                let text = SlackRenderer.plainText(node).joined()
                append(text.isEmpty ? (node.description ?? "") : text, from: node)
            } else if node.children.isEmpty, node.role == "AXButton", let title = node.title {
                append("[\(title)]", from: node)
            } else {
                if node.hasClass("p-rich_text_section") { paragraphRightEdge = node.frame?.maxX }
                for child in node.children { read(child) }
            }
        }

        private mutating func append(_ text: String, from node: Node) {
            body += separator(before: node) + text
            previous = node
        }

        private mutating func appendBlock(_ text: String) {
            body += "\n\(text)\n"
            previous = nil
        }

        /// What goes between the previous inline piece and `node`: a line break, a space, or nothing.
        /// Slack's line breaks and the spacing around mentions are not in the accessibility tree,
        /// so this reads them off where the pieces sit on screen.
        ///
        /// Slack draws a line break as an empty element, which Chromium leaves out of the tree,
        /// and drops whitespace-only text between two mentions. The text-marker API
        /// (`AXStringForTextMarkerRange`) is no help: it returns the same text with neither.
        /// Measured on screen, pieces that touch are 0 or -1 points apart, two mentions with a
        /// space between them 2 points, and a mention followed by inline code 3 points.
        private func separator(before node: Node) -> String {
            guard let previous else { return "" }
            guard let a = previous.frame, let b = node.frame, a.height > 2, b.height > 2 else {
                return guessedSeparator(previous: previous, node: node)
            }
            let lineHeight = min(a.height, b.height)
            let aIsOneLine = a.height < lineHeight * 1.5
            let bIsOneLine = b.height < lineHeight * 1.5
            if b.minY >= a.maxY - 1 {
                // `node` starts on a later line. Text wraps mid-node, so text that starts a line
                // follows a real break. A mention or link moves down whole when it does not fit.
                if node.role == "AXStaticText" { return "\n" }
                guard aIsOneLine else { return "" }
                if let edge = paragraphRightEdge, edge - a.maxX < b.width { return "" }
                return "\n"
            }
            if aIsOneLine, bIsOneLine, b.minX - a.maxX >= 2 { return " " }
            return ""
        }

        /// Used for rows outside the viewport, where Slack reports only horizontal positions. A
        /// piece that starts at or just past the end of the previous one is on the same line.
        /// Otherwise two text nodes in a row are taken as separate lines, and links are set off
        /// with spaces.
        private func guessedSeparator(previous: Node, node: Node) -> String {
            if let a = previous.frame, let b = node.frame, a.width > 0, b.width > 0, b.minX >= a.maxX - 1 {
                return b.minX - a.maxX >= 2 ? " " : ""
            }
            if previous.role == "AXStaticText", node.role == "AXStaticText" { return "\n" }
            return previous.role == "AXLink" || node.role == "AXLink" ? " " : ""
        }

        /// Emoji are images described as "<name> 絵文字" in a Japanese workspace. The English
        /// suffix is a guess and has not been seen.
        private func emojiName(_ image: Node) -> String? {
            guard var name = image.description else { return nil }
            for suffix in [" 絵文字", " emoji"] where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
            }
            return ":\(name):"
        }
    }

    // MARK: Fallback

    /// Every piece of visible text under `node`, one entry per text-bearing element.
    static func plainText(_ node: Node) -> [String] {
        var lines: [String] = []
        func walk(_ node: Node) {
            if node.role == "AXStaticText" {
                if let value = node.value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(value)
                }
                return
            }
            if node.children.isEmpty, let label = node.title ?? node.description {
                lines.append(label)
            }
            node.children.forEach(walk)
        }
        walk(node)
        return lines
    }
}
