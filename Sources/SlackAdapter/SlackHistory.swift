import AXSnapshot

/// Reads messages beyond the ones on screen. Slack only renders the rows near the viewport, so
/// this scrolls the outermost rendered message into view, lets Slack render the rows past it,
/// and repeats. Afterwards it scrolls back down to where the list started.
///
/// What was observed on the Slack desktop app (October 2026) and cannot be read from this code:
/// - A list renders roughly 10 to 15 rows, a few of them outside the viewport, and one scroll
///   brings in 4 to 6 more. A 100-reply thread takes about 30 seconds to read in full.
/// - Scrolling back down ends with the newest message visible. If the list was scrolled part
///   of the way up beforehand, that position is not restored.
/// - Scrolling does not change what Slack considers read.
public enum SlackHistory {
    /// The side effects are injected so the paging logic does not depend on a running Slack.
    public struct Driver {
        public var snapshot: () throws -> [Node]
        /// Scrolls the element with this DOM id into view. Returns false if it no longer exists.
        public var scrollToVisible: (String) -> Bool
        /// Gives Slack time to render after a scroll.
        public var pause: () -> Void
        /// Clicks the element with the given class inside the element with the given DOM id.
        public var press: (_ domID: String, _ descendantClass: String) -> Bool

        public init(
            snapshot: @escaping () throws -> [Node],
            scrollToVisible: @escaping (String) -> Bool,
            pause: @escaping () -> Void,
            press: @escaping (String, String) -> Bool = { _, _ in false }
        ) {
            self.snapshot = snapshot
            self.scrollToVisible = scrollToVisible
            self.pause = pause
            self.press = press
        }
    }

    /// The two message lists Slack can show side by side.
    public enum Pane: Sendable {
        case conversation, thread
    }

    /// What to read from one pane. Each condition scrolls only as far as it needs to; with none
    /// set, nothing scrolls.
    public struct Request {
        public var pane = Pane.conversation
        /// Extra scrolls toward older messages, on top of whatever the conditions below need.
        public var olderPages = 0
        /// A message timestamp to bring into view, whether it is older or newer than what is rendered.
        public var target: String?
        /// Read at least this many of the newest messages, and return only those.
        public var last: Int?
        /// Read back until a message containing this text has been seen.
        public var containing: String?
        /// Read back to the first message.
        public var whole = false
        /// The most scrolls to spend satisfying the conditions.
        public var scrollLimit = 100

        public init() {}
    }

    private static let pollsPerScroll = 10

    /// Returns the current windows with the pane's message list replaced by every row seen while
    /// satisfying `request`. `onTargetRendered` runs once, while the target's row is rendered and
    /// before the list scrolls away from it.
    public static func collect(
        _ request: Request, driver: Driver, onTargetRendered: ((_ rowID: String) -> Void)? = nil
    ) throws -> [Node] {
        let pane = request.pane
        let start = try driver.snapshot()
        var rows = messageRows(pane, in: start)
        guard let originalOldest = rows.first?.domID, let originalNewest = rows.last?.domID,
            SlackInterpreter.rowID(timestamp: "", like: originalOldest) != nil
        else { return start }

        let targetID = request.target.flatMap { SlackInterpreter.rowID(timestamp: $0, like: originalOldest) }
        var notified = false
        func notifyIfRendered(_ rows: [Node]) {
            guard !notified, let targetID, let onTargetRendered else { return }
            if rows.contains(where: { $0.domID == targetID }) {
                notified = true
                onTargetRendered(targetID)
            }
        }
        notifyIfRendered(rows)

        var collected: [String: Node] = [:]
        func keep(_ rows: [Node]) {
            for row in rows {
                guard let id = row.domID else { continue }
                // A row read while on screen has usable geometry; do not replace it with a clipped copy.
                if let existing = collected[id], SlackInterpreter.isOnScreen(existing), !SlackInterpreter.isOnScreen(row) { continue }
                collected[id] = row
            }
        }
        keep(rows)

        func needsOlder(than oldest: String) -> Bool {
            if let targetID, collected[targetID] == nil, SlackInterpreter.rowPrecedes(targetID, oldest) { return true }
            if request.whole { return true }
            if let last = request.last, collected.count < last { return true }
            if let text = request.containing, !collected.values.contains(where: { contains($0, text: text) }) {
                return true
            }
            return false
        }

        // A message that had to be searched for would otherwise sit at the very top with nothing
        // before it, so read one page past it.
        let searchesBack = needsOlder(than: originalOldest) && (request.target != nil || request.containing != nil)
        var extraPages = max(request.olderPages, searchesBack ? 1 : 0)
        let targetIsNewer = targetID.map { SlackInterpreter.rowPrecedes(originalNewest, $0) } ?? false
        var scrollsLeft = request.scrollLimit
        var scrollsUp = 0
        while let oldest = rows.first?.domID, !targetIsNewer {
            if needsOlder(than: oldest), scrollsLeft > 0 {
                scrollsLeft -= 1
            } else if extraPages > 0 {
                extraPages -= 1
            } else {
                break
            }
            // A thread shows a separator under its first message, so its start needs no waiting for.
            if pane == .thread, SlackInterpreter.list(pane, in: try driver.snapshot())?.children.contains(where: SlackInterpreter.isThreadStart) == true {
                break
            }
            guard driver.scrollToVisible(oldest),
                let older = try waitForRows(pane, driver, until: { $0.first?.domID != oldest })
            else { break }  // Nothing older appeared: this is the start of the conversation.
            scrollsUp += 1
            rows = older
            keep(rows)
            notifyIfRendered(rows)
        }

        // Go down to where the list started, or further when the target is newer than that.
        let goal = targetIsNewer ? targetID ?? originalNewest : originalNewest
        if scrollsUp > 0 || targetIsNewer {
            // Each step down reveals only a few rows, so allow several steps per scroll up.
            let stepsDown = scrollsUp * 4 + 4 + (targetIsNewer ? request.scrollLimit : 0)
            for _ in 0..<stepsDown {
                guard let newest = rows.last?.domID, driver.scrollToVisible(newest) else { break }
                if !SlackInterpreter.rowPrecedes(newest, goal) { break }
                guard let newer = try waitForRows(pane, driver, until: { $0.last?.domID != newest }) else { break }
                rows = newer
                keep(rows)
                notifyIfRendered(rows)
            }
        }

        var merged = collected.keys.sorted(by: SlackInterpreter.rowPrecedes).compactMap { collected[$0] }
        if let last = request.last { merged = Array(merged.suffix(last)) }
        var replaced = false
        return start.map { replaceList(pane, in: $0, with: merged, replaced: &replaced) }
    }

    /// Makes sure the thread started by the message `root` is showing in the thread pane.
    /// Returns false if the message cannot be found in the open conversation or has no thread.
    /// The only thing it clicks is that message's reply count.
    ///
    /// Pressing the reply count opens the thread within about two seconds, replacing any thread
    /// that was open, and leaves Slack in the background. A thread that is already open can only
    /// be recognised while its first message is rendered, which a long thread scrolled to the
    /// bottom does not do.
    public static func openThread(root: String, driver: Driver) throws -> Bool {
        if threadIsOpen(try driver.snapshot(), root: root) { return true }
        var request = Request()
        request.target = root
        var pressed = false
        _ = try collect(request, driver: driver) { rowID in
            pressed = driver.press(rowID, SlackInterpreter.replyCountClass)
        }
        guard pressed else { return false }
        for _ in 0..<pollsPerScroll {
            driver.pause()
            if threadIsOpen(try driver.snapshot(), root: root) { return true }
        }
        return false
    }

    public static func hasList(_ pane: Pane, in windows: [Node]) -> Bool {
        SlackInterpreter.list(pane, in: windows) != nil
    }

    /// The rows of the pane's message list, oldest first.
    public static func messageRows(_ pane: Pane, in windows: [Node]) -> [Node] {
        SlackInterpreter.list(pane, in: windows)?.children.filter(SlackInterpreter.isPagingMessageRow) ?? []
    }

    /// Whether the message's visible text contains `text`, ignoring case.
    public static func contains(_ row: Node, text: String) -> Bool {
        SlackInterpreter.plainText(row).joined(separator: " ").localizedCaseInsensitiveContains(text)
    }

    /// The thread pane lists the thread's first message at the top.
    private static func threadIsOpen(_ windows: [Node], root: String) -> Bool {
        windows.contains { window in
            window.all(where: SlackInterpreter.isThreadView).contains { SlackInterpreter.contains([$0], timestamp: root) }
        }
    }

    /// Polls until the rendered rows satisfy `changed`. Returns nil if they never do.
    private static func waitForRows(_ pane: Pane, _ driver: Driver, until changed: ([Node]) -> Bool) throws -> [Node]? {
        for _ in 0..<pollsPerScroll {
            driver.pause()
            let rows = try messageRows(pane, in: driver.snapshot())
            if changed(rows) { return rows }
        }
        return nil
    }

    private static func replaceList(_ pane: Pane, in node: Node, with rows: [Node], replaced: inout Bool) -> Node {
        guard !replaced else { return node }
        var node = node
        let inThread = SlackInterpreter.isThreadView(node)
        if pane == .thread, inThread {
            var done = false
            node.children = node.children.map { replaceFirstList(in: $0, with: rows, replaced: &done) }
            replaced = true
        } else if pane == .conversation, !inThread, SlackInterpreter.isMessageList(node) {
            node.children = rows
            replaced = true
        } else if !inThread {
            node.children = node.children.map { replaceList(pane, in: $0, with: rows, replaced: &replaced) }
        }
        return node
    }

    private static func replaceFirstList(in node: Node, with rows: [Node], replaced: inout Bool) -> Node {
        guard !replaced else { return node }
        var node = node
        if SlackInterpreter.isMessageList(node) {
            node.children = rows
            replaced = true
        } else {
            node.children = node.children.map { replaceFirstList(in: $0, with: rows, replaced: &replaced) }
        }
        return node
    }
}
