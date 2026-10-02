import AXSnapshot
import Foundation

public struct SlackScreen: Equatable, Sendable {
    public var workspace: String?
    public var views: [SlackView]
}

public struct SlackView: Equatable, Sendable {
    public enum Kind: Sendable { case conversation, thread, search, unknown }
    public var title: String?
    public var kind: Kind
    public var searchSummary: [String]
    public var messages: [SlackMessage]
    public var draft: String?
    public var plainText: [String]
}

public struct SlackMessage: Equatable, Sendable {
    public enum Inline: Equatable, Sendable {
        case text(String), button(String), threadOrigin(String)
    }
    public indirect enum Block: Equatable, Sendable {
        case paragraph([Inline]), quote([Block]), file(String)
    }
    public var rowID: String?
    public var timestamp: String?
    public var sentDate: Date?
    public var timeLabel: String?
    public var sender: String?
    public var labelledSender: String?
    public var location: [Block]
    public var body: [Block]
    public var replies: String?
    public var reactions: [String]
}

/// Interprets Slack's accessibility DOM; unrecognised content falls through as text.
/// Conversation rows end in `message-list_<seconds>.<micros>`; date dividers instead end in
/// `<milliseconds>.<conversation id>`. Thread rows end in `Thread_<timestamp>` and use the
/// same list prefix for separators and the input. Only the final timestamp identifies a message.
public enum SlackInterpreter {
    public static let bundleID = "com.tinyspeck.slackmacgap"
    static let replyCountClass = "c-message__reply_count"
    private static let rowIDPrefix = "message-list_"

    public static func read(_ windows: [Node]) -> [SlackScreen] {
        windows.map { window in
            let workspace = window.first { $0.hasClass("p-client_workspace_wrapper") }?.description
            let views = window.all { $0.hasClass("p-view_contents") }.compactMap { view -> SlackView? in
                let rows = view.all(where: isDisplayMessageRow)
                let sidebar = view.hasClass("p-view_contents--sidebar")
                if sidebar, rows.isEmpty { return nil }
                let kind: SlackView.Kind = isThreadView(view) ? .thread
                    : sidebar ? .search : hasList(.conversation, in: [view]) ? .conversation : .unknown
                return SlackView(title: view.description, kind: kind, searchSummary: searchSummary(view),
                    messages: rows.map(readMessage), draft: draft(in: view),
                    plainText: rows.isEmpty ? plainText(view) : [])
            }
            return SlackScreen(workspace: workspace, views: views)
        }
    }

    private static func readMessage(_ row: Node) -> SlackMessage {
        var reader = MessageReader()
        reader.read(row)
        reader.flushParagraph()
        let labelled = row.title?.range(of: " : ").map { String(row.title![..<$0.lowerBound]) }
        return SlackMessage(rowID: row.domID, timestamp: row.domID.flatMap(timestamp), sentDate: sentDate(of: row),
            timeLabel: reader.timeLabel, sender: reader.sender, labelledSender: labelled, location: reader.location,
            body: reader.blocks, replies: reader.replies, reactions: reader.reactions)
    }

    /// Display rows include search results; paging rows must belong to a virtual list.
    static func isDisplayMessageRow(_ node: Node) -> Bool {
        node.children.contains { $0.hasClass("c-message_kit__hover") }
    }

    static func isPagingMessageRow(_ node: Node) -> Bool {
        node.hasClass("c-virtual_list__item") && node.first { $0.hasClass("c-message_kit__hover") } != nil
    }

    static func isMessageList(_ node: Node) -> Bool {
        node.children.contains(where: isPagingMessageRow)
    }

    /// Beside search results the thread can be marked primary; its inner container identifies it.
    static func isThreadView(_ node: Node) -> Bool {
        guard node.hasClass("p-view_contents") || node.hasClass("p-view_contents--secondary") else { return false }
        return node.hasClass("p-view_contents--secondary") || node.first { $0.hasClass("p-threads_flexpane_container") } != nil
    }

    static func isThreadStart(_ node: Node) -> Bool { node.domID?.hasSuffix("_separator") == true }
    /// Slack flattens offscreen rows to a one-point-high frame.
    static func isOnScreen(_ node: Node) -> Bool { (node.frame?.height ?? 0) > 2 }

    static func timestamp(_ rowID: String) -> String? {
        guard let separator = rowID.lastIndex(of: "_") else { return nil }
        return String(rowID[rowID.index(after: separator)...])
    }

    static func rowID(timestamp: String, like rowID: String) -> String? {
        guard let separator = rowID.lastIndex(of: "_") else { return nil }
        return String(rowID[...separator]) + timestamp
    }

    /// Per-list prefixes and fixed-width timestamps make lexical order chronological.
    static func rowPrecedes(_ lhs: String, _ rhs: String) -> Bool { lhs < rhs }

    public static func contains(_ windows: [Node], timestamp: String) -> Bool {
        windows.contains { window in
            window.first { isPagingMessageRow($0) && $0.domID?.hasSuffix("_" + timestamp) == true } != nil
        }
    }

    public static func openChannelID(_ windows: [Node]) -> String? {
        for window in windows {
            guard let list = window.first(where: isMessageList) else { continue }
            for row in list.children {
                guard let id = row.domID, id.hasPrefix(rowIDPrefix),
                    let suffix = id.split(separator: ".").last, suffix.first?.isLetter == true
                else { continue }
                return String(suffix)
            }
        }
        return nil
    }

    public static func hasList(_ pane: SlackHistory.Pane, in windows: [Node]) -> Bool { list(pane, in: windows) != nil }

    static func list(_ pane: SlackHistory.Pane, in windows: [Node]) -> Node? {
        func find(_ node: Node) -> Node? {
            if isThreadView(node) { return pane == .thread ? node.first(where: isMessageList) : nil }
            if pane == .conversation, isMessageList(node) { return node }
            for child in node.children { if let hit = find(child) { return hit } }
            return nil
        }
        for window in windows { if let hit = find(window) { return hit } }
        return nil
    }

    private static func searchSummary(_ view: Node) -> [String] {
        func text(classPrefix: String) -> String? {
            view.first { $0.domClasses.contains { $0.hasPrefix(classPrefix) } }
                .map { $0.children.filter { $0.role == "AXStaticText" }.compactMap(\.value).joined() }
        }
        return [text(classPrefix: "headerContainer__"), text(classPrefix: "resultCounts__")]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func draft(in view: Node) -> String? {
        let text = view.first { $0.role == "AXTextArea" && $0.hasClass("ql-editor") }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func sentDate(of row: Node) -> Date? {
        guard let id = row.domID, let separator = id.lastIndex(of: "_") else { return nil }
        let parts = id[id.index(after: separator)...].split(separator: ".")
        guard parts.count == 2, let seconds = TimeInterval(parts[0]), parts[1].allSatisfy(\.isNumber) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private struct MessageReader {
        var sender: String?
        var timeLabel: String?
        /// Where the message was posted, which search results show between the sender and the time.
        var location: [SlackMessage.Block] = []
        var body = ""
        var inline: [SlackMessage.Inline] = []
        var blocks: [SlackMessage.Block] = []
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
                flushParagraph()
                location = blocks
                blocks = []
                previous = nil
            } else if node.hasClass("c-message__reply_count") {
                replies = node.title
            } else if MessageReader.chrome.contains(where: node.hasClass) {
                return
            } else if node.hasClass("c-reaction_bar") {
                for reaction in node.all(where: { $0.hasClass("c-reaction") }) {
                    let emoji = reaction.first { $0.role == "AXImage" }.flatMap(emojiName) ?? "?"
                    let count = reaction.first { $0.role == "AXStaticText" }?.value ?? "1"
                    reactions.append("\(emoji) \(count)")
                }
            } else if node.hasClass("c-message_attachment") {
                // A message shared from elsewhere: quote it so it is not read as the sender's words.
                var quoted = MessageReader()
                for child in node.children { quoted.read(child) }
                quoted.flushParagraph()
                appendBlock(.quote(quoted.blocks))
            } else if node.hasClass("c-pillow_file_container") {
                appendBlock(.file(node.description ?? SlackInterpreter.plainText(node).joined(separator: " ")))
            } else if node.hasClass("c-message__broadcast_preamble_link") {
                // The start of the thread this reply was also sent to the channel from.
                body += " "
                flushText()
                inline.append(.threadOrigin(node.title ?? ""))
                body = "\n"
                previous = nil
            } else if node.hasClass("c-mrkdwn__code") {
                append("`\(SlackInterpreter.plainText(node).joined())`", from: node)
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
                let text = SlackInterpreter.plainText(node).joined()
                append(text.isEmpty ? (node.description ?? "") : text, from: node)
            } else if node.children.isEmpty, node.role == "AXButton", let title = node.title {
                body += separator(before: node)
                flushText()
                inline.append(.button(title))
                previous = node
            } else {
                if node.hasClass("p-rich_text_section") { paragraphRightEdge = node.frame?.maxX }
                for child in node.children { read(child) }
            }
        }

        private mutating func append(_ text: String, from node: Node) {
            body += separator(before: node) + text
            previous = node
        }

        private mutating func flushText() {
            if !body.isEmpty { inline.append(.text(body)) }
            body = ""
        }

        mutating func flushParagraph() {
            flushText()
            if !inline.isEmpty { blocks.append(.paragraph(inline)) }
            inline = []
        }

        private mutating func appendBlock(_ block: SlackMessage.Block) {
            flushParagraph()
            blocks.append(block)
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
