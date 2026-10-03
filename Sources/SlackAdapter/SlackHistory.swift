import AXTree

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
        _ request: Request, driver: Driver, initial: [Node]? = nil, observations: [[Node]] = [],
        onTargetRendered: ((_ rowID: String) -> Void)? = nil
    ) throws -> [Node] {
        let start = try initial ?? driver.snapshot()
        var plan = Plan(request, observation: SlackInterpreter.historyObservation(request.pane, in: start),
                        notifyTarget: onTargetRendered != nil)
        for windows in observations {
            plan.remember(SlackInterpreter.historyObservation(request.pane, in: windows))
        }
        try run(&plan, driver: driver, onTargetRendered: onTargetRendered)
        var replaced = false
        return start.map { replaceList(request.pane, in: $0, with: plan.mergedRows, replaced: &replaced) }
    }

    /// Opens the root message's reply count, then waits for that thread to appear.
    /// An already open thread is recognised only while its first message is rendered.
    /// `onThreadRead` receives snapshots with the requested root in an open thread, including
    /// observations made while restoring the conversation after the click.
    public static func openThread(
        root: String, driver: Driver, onThreadRead: (([Node]) -> Void)? = nil
    ) throws -> Bool {
        var observingDriver = driver
        observingDriver.snapshot = {
            let windows = try driver.snapshot()
            if let onThreadRead,
               SlackInterpreter.historyObservation(.thread, in: windows).openThreadRoots.contains(root) {
                onThreadRead(windows)
            }
            return windows
        }
        var request = Request()
        request.target = root
        var plan = Plan(request, observation: SlackInterpreter.historyObservation(.conversation, in: try observingDriver.snapshot()),
                        openingThread: root)
        try run(&plan, driver: observingDriver)
        return plan.threadOpened
    }

    private static func run(
        _ plan: inout Plan, driver: Driver, onTargetRendered: ((String) -> Void)? = nil
    ) throws {
        var observation: SlackInterpreter.HistoryObservation?
        var succeeded = true
        while true {
            switch plan.next(after: observation, succeeded: succeeded) {
            case .observe:
                observation = SlackInterpreter.historyObservation(plan.request.pane, in: try driver.snapshot())
                if let observation { plan.retainUnrecognised(observation) }
            case let .scroll(id, change):
                succeeded = driver.scrollToVisible(id)
                if succeeded, let change {
                    observation = try wait(plan.request.pane, driver, for: change, observe: { plan.retainUnrecognised($0) })
                } else {
                    observation = nil
                }
            case let .notify(id):
                onTargetRendered?(id)
            case let .press(id):
                succeeded = driver.press(id, SlackInterpreter.replyCountClass)
            case let .waitForThread(root):
                observation = try wait(plan.request.pane, driver, for: .thread(root))
            case .done:
                return
            }
        }
    }

    private static func wait(
        _ pane: Pane, _ driver: Driver, for change: Change,
        observe: (SlackInterpreter.HistoryObservation) -> Void = { _ in }
    ) throws -> SlackInterpreter.HistoryObservation? {
        for _ in 0..<pollsPerScroll {
            driver.pause()
            let observation = SlackInterpreter.historyObservation(pane, in: try driver.snapshot())
            observe(observation)
            if change.matches(observation) { return observation }
        }
        return nil
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

    private static func replaceList(_ pane: Pane, in node: Node, with rows: [Node], replaced: inout Bool) -> Node {
        guard !replaced, !SlackInterpreter.isSidebar(node) else { return node }
        var node = node
        let inThread = SlackInterpreter.isThreadView(node)
        if pane == .thread, inThread {
            var done = false
            node.children = node.children.map { replaceFirstList(in: $0, with: rows, replaced: &done) }
            replaced = true
        } else if pane == .conversation, !inThread, SlackInterpreter.isCollectionList(node) {
            node.children = rows
            replaced = true
        } else if !inThread {
            node.children = node.children.map { replaceList(pane, in: $0, with: rows, replaced: &replaced) }
        }
        return node
    }

    private static func replaceFirstList(in node: Node, with rows: [Node], replaced: inout Bool) -> Node {
        guard !replaced, !SlackInterpreter.isSidebar(node) else { return node }
        var node = node
        if SlackInterpreter.isCollectionList(node) {
            node.children = rows
            replaced = true
        } else {
            node.children = node.children.map { replaceFirstList(in: $0, with: rows, replaced: &replaced) }
        }
        return node
    }
}
