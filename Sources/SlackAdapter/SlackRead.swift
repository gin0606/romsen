import AXTree

/// Pure decisions between observing Slack, opening a thread, reading, and formatting.
public enum SlackRead {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Options {
        public let target: SlackLink?
        public let last: Int?
        public let find: String?
        public let context: Int
        public let history: Int
        public let thread: Bool

        public init(link: String? = nil, last: Int? = nil, find: String? = nil,
                    context: Int = 5, history: Int = 0, thread: Bool = false) throws {
            if let link {
                guard let parsed = SlackLink(link) else { throw Failure(description: "not a Slack message link: \(link)") }
                target = parsed
            } else {
                target = nil
            }
            self.last = last
            self.find = find
            self.context = context
            self.history = history
            self.thread = thread
        }
    }

    public enum Action {
        case read(SlackHistory.Request)
        case openThread(root: String, then: SlackHistory.Request)
    }

    public struct Output {
        public let focus: SlackRenderer.Focus?
        public let only: SlackHistory.Pane?
    }

    public static func prepare(_ options: Options, in current: [Node]) throws -> Action {
        var request = SlackHistory.Request()
        request.olderPages = options.history
        request.last = options.last
        request.containing = options.find
        if let target = options.target {
            // Reject a different conversation before any scrolling or thread click.
            if let open = SlackInterpreter.openChannelID(current), open != target.channelID {
                throw Failure(description:
                    "the link points to conversation \(target.channelID), but Slack is showing \(open). "
                    + "Open that conversation in Slack and run this again.")
            }
            request.target = target.timestamp
            request.whole = options.thread
            if let root = target.threadTimestamp ?? (options.thread ? target.timestamp : nil) {
                request.pane = .thread
                return .openThread(root: root, then: request)
            }
        } else {
            if options.thread || !SlackHistory.hasList(.conversation, in: current) {
                if SlackHistory.hasList(.thread, in: current) {
                    request.pane = .thread
                } else if options.thread {
                    throw Failure(description: "no thread is open in Slack.")
                }
            }
            request.whole = options.thread && options.last == nil && options.find == nil
        }
        return .read(request)
    }

    public static func afterOpeningThread(root: String, opened: Bool, in current: [Node]) throws {
        // A long open thread may have scrolled its root out of the rendered rows.
        guard opened || SlackHistory.hasList(.thread, in: current) else {
            throw Failure(description: "could not open the thread of message \(root) in the open conversation.")
        }
    }

    public static func output(_ options: Options, request: SlackHistory.Request, in windows: [Node],
                              limitToPane: Bool = false) throws -> Output {
        var focus: SlackRenderer.Focus?
        if let target = options.target {
            let found = limitToPane
                ? SlackHistory.messageRows(request.pane, in: windows).contains { $0.domID?.hasSuffix("_" + target.timestamp) == true }
                : SlackInterpreter.contains(windows, timestamp: target.timestamp)
            guard found else {
                throw Failure(description: "message \(target.timestamp) was not found in the open conversation.")
            }
            focus = .init(timestamp: target.timestamp, context: options.context, wholeThread: options.thread)
        } else if let find = options.find {
            let rows = SlackHistory.messageRows(request.pane, in: windows)
            guard let match = rows.last(where: { SlackHistory.contains($0, text: find) })?.domID else {
                throw Failure(description: "no message containing \"\(find)\" was found in the last \(rows.count) messages.")
            }
            focus = .init(row: match, context: options.context)
        }
        return Output(focus: focus, only: limitToPane || options.last != nil || (options.thread && options.target == nil) ? request.pane : nil)
    }
}
