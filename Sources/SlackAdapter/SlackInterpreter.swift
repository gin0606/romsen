import AXTree
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
    public var unidentifiedRowIDs: [String] = []
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
    public var fallbackText: [String]? = nil
    public var isFallback = false
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
            let containers = window.all { $0.hasClass("p-view_contents") }
            var views = containers.compactMap { view -> SlackView? in
                let rows = view.all { isPagingMessageRow($0) || isDisplayMessageRow($0) || isMessageCandidate($0) }
                let sidebar = isSidebar(view)
                if sidebar, rows.isEmpty { return nil }
                let kind: SlackView.Kind = isThreadView(view) ? .thread
                    : sidebar ? .search : list(.conversation, in: [view], includeUnrecognised: true) != nil
                        || view.hasClass("p-view_contents--primary")
                        || view.first(where: { $0.role == "AXList" }) != nil ? .conversation : .unknown
                return SlackView(title: view.description, kind: kind, searchSummary: searchSummary(view),
                    messages: readMessages(rows), draft: draft(in: view),
                    plainText: rows.isEmpty ? plainText(view) : [])
            }
            let remainder = removingViews(from: window)
            let remainingText = textOutsideViews(window)
            let hasUncontainedRows = remainder.first {
                isDisplayMessageRow($0) || isUnrecognisedMessageRow($0)
            } != nil
            if containers.isEmpty || hasUncontainedRows {
                views.append(SlackView(title: nil, kind: .unknown, searchSummary: [], messages: [],
                    plainText: containers.isEmpty ? plainText(window) : remainingText,
                    unidentifiedRowIDs: remainder.all(where: isPagingMessageRow).compactMap(\.domID)))
            }
            return SlackScreen(workspace: workspace, views: views)
        }
    }

    private static func removingViews(from node: Node) -> Node {
        var remainder = node
        remainder.children = node.children.filter { !$0.hasClass("p-view_contents") }.map(removingViews)
        return remainder
    }

    private static func textOutsideViews(_ node: Node) -> [String] {
        if node.hasClass("p-view_contents") { return [] }
        if node.children.isEmpty { return plainText(node) }
        return node.children.flatMap(textOutsideViews)
    }

    private static func readMessages(_ rows: [Node]) -> [SlackMessage] {
        var messages: [SlackMessage] = []
        for row in rows {
            if let display = row.first(where: isDisplayMessageRow) {
                var message = readMessage(display)
                message.rowID = row.domID ?? message.rowID
                message.timestamp = row.domID.flatMap(timestamp) ?? message.timestamp
                messages.append(message)
            } else if let id = row.domID, let index = messages.lastIndex(where: { $0.rowID == id }) {
                messages[index].fallbackText = (messages[index].fallbackText ?? []) + plainText(row)
            } else {
                messages.append(SlackMessage(rowID: row.domID, timestamp: row.domID.flatMap(timestamp),
                    location: [], body: [], reactions: [], fallbackText: plainText(row), isFallback: true))
            }
        }
        return messages
    }

    public enum Diagnostic: String, Sendable {
        case unknownStructure = "Slack view or message structure was not recognised; output may be incomplete. Available text is included where the requested scope can be identified."
        case unidentifiedPane = "The requested Slack pane could not be identified; output may be incomplete. Unidentified text was omitted."
    }

    public static func diagnostics(
        _ screens: [SlackScreen], focus: SlackRenderer.Focus? = nil, only: SlackHistory.Pane? = nil, last: Int? = nil
    ) -> [Diagnostic] {
        let views = screens.flatMap(\.views)
        let selected = views.filter { $0.matches(only: only) }
        var result: [Diagnostic] = []
        if selected.contains(where: { view in
            guard let rows = view.selectedMessages(focus: focus, last: last) else { return false }
            return view.kind == .unknown || rows.contains { $0.fallbackText != nil }
        }) {
            result.append(.unknownStructure)
        }
        let omittedTarget = focus.map { focus in
            if only != nil, selected.contains(where: { $0.selectedMessages(focus: focus) != nil }) { return false }
            return views.contains { view in
                view.unidentifiedRowIDs.contains { $0 == focus.row || timestamp($0) == focus.row }
            }
        } ?? false
        if omittedTarget || (only != nil && selected.isEmpty && views.contains(where: { $0.kind == .unknown })) {
            result.append(.unidentifiedPane)
        }
        return result
    }

    /// Timestamp-shaped message IDs survive some class changes. Date dividers and composers
    /// share the prefix, so neither the prefix nor an empty message body is enough evidence.
    static func isMessageCandidate(_ node: Node) -> Bool {
        guard let id = node.domID, id.hasPrefix(rowIDPrefix), let suffix = timestamp(id) else { return false }
        let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].count == 10 && parts[1].count == 6
            && parts.allSatisfy { $0.utf8.allSatisfy { (48...57).contains($0) } }
    }

    static func isUnrecognisedMessageRow(_ node: Node) -> Bool {
        isMessageCandidate(node) && node.first(where: isDisplayMessageRow) == nil
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

    /// Identifies the open thread only when its root and reply separator are captured.
    public static func openThreadRoot(in windows: [Node]) -> String? {
        guard let list = list(.thread, in: windows),
              let separator = list.children.firstIndex(where: isThreadStart),
              let root = list.children[..<separator].first(where: isPagingMessageRow) else { return nil }
        return root.domID.flatMap(timestamp)
    }

    public static func hasList(_ pane: SlackHistory.Pane, in windows: [Node], includeUnrecognised: Bool = false) -> Bool {
        list(pane, in: windows, includeUnrecognised: includeUnrecognised) != nil
    }

    static func isSidebar(_ node: Node) -> Bool { node.hasClass("p-view_contents--sidebar") }

    static func isCollectionList(_ node: Node) -> Bool {
        if isMessageList(node) || node.children.contains(where: isMessageCandidate) { return true }
        return node.children.lazy.filter(containsCollectionRow).prefix(2).count == 2
    }

    private static func containsCollectionRow(_ node: Node) -> Bool {
        if node.hasClass("p-view_contents") || isThreadView(node) || isSidebar(node) { return false }
        return isPagingMessageRow(node) || isDisplayMessageRow(node) || isMessageCandidate(node)
            || node.children.contains(where: containsCollectionRow)
    }

    static func list(_ pane: SlackHistory.Pane, in windows: [Node], includeUnrecognised: Bool = false) -> Node? {
        let matches = includeUnrecognised ? isCollectionList : isMessageList
        func find(_ node: Node) -> Node? {
            if isSidebar(node) { return nil }
            if isThreadView(node) { return pane == .thread ? node.first(where: matches) : nil }
            if pane == .conversation, matches(node) { return node }
            for child in node.children { if let hit = find(child) { return hit } }
            return nil
        }
        for window in windows { if let hit = find(window) { return hit } }
        return nil
    }

    struct HistoryObservation {
        var rows: [Node]
        var atThreadStart: Bool
        var openThreadRoots: Set<String>
    }

    static func historyObservation(_ pane: SlackHistory.Pane, in windows: [Node]) -> HistoryObservation {
        let list = list(pane, in: windows, includeUnrecognised: true)
        let roots = windows.flatMap { $0.all(where: isThreadView) }
            .flatMap { $0.all(where: isPagingMessageRow) }.compactMap { $0.domID.flatMap(timestamp) }
        let rows = list?.children.flatMap { child in
            child.all { isPagingMessageRow($0) || isDisplayMessageRow($0) || isMessageCandidate($0) }
        } ?? []
        return HistoryObservation(rows: rows,
                                  atThreadStart: list?.children.contains(where: isThreadStart) == true,
                                  openThreadRoots: Set(roots))
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
