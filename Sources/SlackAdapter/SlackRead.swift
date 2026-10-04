import AXTree

/// Pure decisions between observing Slack, opening a thread, reading, and formatting.
package enum SlackRead {
    package struct Failure: Error, CustomStringConvertible {
        package let description: String
    }

    package struct Options {
        package let target: SlackLink?
        package let last: Int?
        package let find: String?
        package let context: Int
        package let history: Int
        package let thread: Bool

        package init(link: String? = nil, last: Int? = nil, find: String? = nil,
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

    package enum Action {
        case read(SlackHistory.Request)
        case openThread(root: String, then: SlackHistory.Request)
    }

    package struct Output {
        package let focus: SlackRenderer.Focus?
        package let only: SlackHistory.Pane?
        package let last: Int?
    }

    package static func prepare(_ options: Options, in current: [Node]) throws -> Action {
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
            if options.thread || !SlackInterpreter.hasList(.conversation, in: current, includeUnrecognised: true) {
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

    /// How to reach the thread of `root` before reading it.
    package struct ThreadOpening: Equatable, Sendable {
        /// The thread is open in the current tree, so it counts as opened without a click.
        package let alreadyOpen: Bool
        /// Click the root's reply control to open the thread.
        package let press: Bool
        /// When the click cannot confirm the thread, observe again to check for an open thread.
        package let rereadIfUnconfirmed: Bool
        /// Start collecting from the last thread observed while opening instead of the current tree.
        package let startFromThreadRead: Bool
    }

    package static func openingThread(root: String, in current: [Node], source: SlackHistory.Source) -> ThreadOpening {
        let alreadyOpen = SlackInterpreter.openThreadRoot(in: current) == root
        // A saved tree cannot confirm navigation to a different thread.
        let press = !alreadyOpen && source == .live
        return ThreadOpening(alreadyOpen: alreadyOpen, press: press,
                             rereadIfUnconfirmed: source == .live, startFromThreadRead: press)
    }

    package static func afterOpeningThread(root: String, opened: Bool, in current: [Node]) throws {
        // A long open thread may have scrolled its root out of the rendered rows.
        guard opened || SlackHistory.hasList(.thread, in: current) else {
            throw Failure(description: "could not open the thread of message \(root) in the open conversation.")
        }
    }

    package static func output(_ options: Options, request: SlackHistory.Request, in windows: [Node]) throws -> Output {
        var focus: SlackRenderer.Focus?
        if let target = options.target {
            // Another pane may show a copy of the target, such as an open thread's root; never substitute it.
            guard SlackInterpreter.contains(request.pane, in: windows, timestamp: target.timestamp) else {
                let pane = request.pane == .thread ? "thread" : "conversation"
                throw Failure(description: "message \(target.timestamp) was not found in the open \(pane).")
            }
            focus = .init(timestamp: target.timestamp, context: options.context, wholeThread: options.thread)
        } else if let find = options.find {
            let rows = SlackHistory.messageRows(request.pane, in: windows)
            guard let match = rows.last(where: { SlackHistory.contains($0, text: find) })?.domID else {
                throw Failure(description: "no message containing \"\(find)\" was found in the last \(rows.count) messages.")
            }
            focus = .init(row: match, context: options.context)
        }
        return Output(focus: focus,
                      only: options.target != nil || options.last != nil || options.thread ? request.pane : nil,
                      last: options.last)
    }
}

extension SlackView {
    func matches(only: SlackHistory.Pane?) -> Bool {
        only == nil || kind == (only == .thread ? .thread : .conversation)
    }

    func selectedMessages(focus: SlackRenderer.Focus?, last: Int? = nil) -> [SlackMessage]? {
        guard let focus else { return last.map { Array(messages.suffix($0)) } ?? messages }
        guard let index = messages.firstIndex(where: focus.matches) else { return nil }
        if focus.wholeThread && kind == .thread { return messages }
        let context = min(focus.context, messages.count)
        return Array(messages[max(index - context, 0)...min(index + context, messages.count - 1)])
    }
}
