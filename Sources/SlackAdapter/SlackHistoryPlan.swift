import AXTree

extension SlackHistory {
    enum Change: Equatable {
        case older(String), newer(String), thread(String)

        func matches(_ observation: SlackInterpreter.HistoryObservation) -> Bool {
            switch self {
            case let .older(id): observation.rows.first?.domID != id
            case let .newer(id): observation.rows.last?.domID != id
            case let .thread(root): observation.openThreadRoots.contains(root)
            }
        }
    }

    enum Action: Equatable {
        case observe
        case scroll(String, Change?)
        case notify(String)
        case press(String)
        case waitForThread(String)
        case done
    }

    /// A value-only transition: feed back the observation (nil when waiting expired) and the
    /// operation's result to get the next action. It never reads or changes Slack itself.
    struct Plan {
        let request: Request
        private let openingThread: String?
        private let notifyTarget: Bool
        let validList: Bool
        private let targetID: String?
        private let originalNewest: String?
        private let targetIsNewer: Bool
        private var rows: [Node]
        private var collected: [String: Node] = [:]
        private var unrecognised: [String: Node] = [:]
        private var extraPages: Int
        private var scrollsLeft: Int
        private var scrollsUp = 0
        private var stepsDown: Int?
        private var notified = false
        private var pressed = false
        private(set) var threadOpened: Bool
        private enum Phase { case reading, restoring, finished, done }
        private var phase = Phase.reading
        private var pending = Action.done

        init(_ request: Request, observation: SlackInterpreter.HistoryObservation,
             openingThread: String? = nil, notifyTarget: Bool = false) {
            self.request = request
            self.openingThread = openingThread
            self.notifyTarget = notifyTarget
            rows = observation.rows
            validList = rows.first?.domID.map { SlackInterpreter.rowID(timestamp: "", like: $0) != nil } == true
                && rows.last?.domID != nil
            let newest = rows.last?.domID
            originalNewest = newest
            targetID = rows.first?.domID.flatMap { first in
                request.target.flatMap { SlackInterpreter.rowID(timestamp: $0, like: first) }
            }
            targetIsNewer = targetID.map { target in
                newest.map { SlackInterpreter.rowPrecedes($0, target) } ?? false
            } ?? false
            extraPages = request.olderPages
            scrollsLeft = request.scrollLimit
            threadOpened = openingThread.map { observation.openThreadRoots.contains($0) } ?? false
            retainUnrecognised(observation)
            keep(rows)
            if validList, let oldest = rows.first?.domID {
                // Searching backwards includes one page before the match for context.
                if needsOlder(than: oldest), request.target != nil || request.containing != nil {
                    extraPages = max(extraPages, 1)
                }
            } else {
                phase = .done
            }
            if threadOpened { phase = .done }
        }

        var mergedRows: [Node] {
            let ids = Set(collected.keys).union(unrecognised.keys).sorted(by: SlackInterpreter.rowPrecedes)
            let selected = request.last.map { Array(ids.suffix($0)) } ?? ids
            var merged = selected.flatMap { id -> [Node] in
                guard let row = collected[id] else { return unrecognised[id].map { [$0] } ?? [] }
                if let unknown = unrecognised[id], !SlackInterpreter.isUnrecognisedMessageRow(row) {
                    return [row, unknown]
                }
                return [unrecognised[id] ?? row]
            }
            // Rows without IDs cannot drive scrolling, but their text is still readable.
            for (index, row) in rows.enumerated() where row.domID == nil {
                let following = rows.dropFirst(index + 1).compactMap(\.domID)
                let position = merged.firstIndex { candidate in
                    candidate.domID.map { following.contains($0) } ?? false
                } ?? merged.endIndex
                merged.insert(row, at: position)
            }
            return merged
        }

        mutating func next(after observation: SlackInterpreter.HistoryObservation? = nil,
                           succeeded: Bool = true) -> Action {
            switch pending {
            case .scroll(_, .older):
                if succeeded, let observation {
                    rows = observation.rows
                    keep(rows)
                    scrollsUp += 1
                } else {
                    phase = .restoring
                }
            case .scroll(_, .newer):
                if succeeded, let observation {
                    rows = observation.rows
                    keep(rows)
                } else {
                    phase = .finished
                }
            case .scroll(_, nil), .scroll(_, .thread): phase = .finished
            case .press: pressed = succeeded
            case .waitForThread:
                threadOpened = openingThread.map { observation?.openThreadRoots.contains($0) == true } ?? false
                phase = .done
            case .observe:
                if observation?.atThreadStart == true {
                    phase = .restoring
                } else if let oldest = rows.first?.domID {
                    pending = .scroll(oldest, .older(oldest))
                    return pending
                }
            case .notify, .done: break
            }

            if phase != .done, !notified, let targetID,
               rows.contains(where: { $0.domID == targetID }), openingThread != nil || notifyTarget {
                notified = true
                pending = openingThread == nil ? .notify(targetID) : .press(targetID)
                return pending
            }

            if phase == .reading {
                if let oldest = rows.first?.domID, !targetIsNewer {
                    if needsOlder(than: oldest), scrollsLeft > 0 {
                        scrollsLeft -= 1
                    } else if extraPages > 0 {
                        extraPages -= 1
                    } else {
                        phase = .restoring
                    }
                    if phase == .reading {
                        pending = request.pane == .thread ? .observe : .scroll(oldest, .older(oldest))
                        return pending
                    }
                } else {
                    phase = .restoring
                }
            }

            if phase == .restoring {
                if stepsDown == nil {
                    stepsDown = scrollsUp > 0 || targetIsNewer
                        ? scrollsUp * 4 + 4 + (targetIsNewer ? request.scrollLimit : 0) : 0
                }
                if let newest = rows.last?.domID, let goal = targetIsNewer ? targetID : originalNewest,
                   stepsDown! > 0 {
                    stepsDown! -= 1
                    pending = .scroll(newest, SlackInterpreter.rowPrecedes(newest, goal) ? .newer(newest) : nil)
                    return pending
                }
                phase = .finished
            }

            if phase == .finished, let openingThread, pressed {
                pending = .waitForThread(openingThread)
                return pending
            }
            phase = .done
            pending = .done
            return pending
        }

        private func needsOlder(than oldest: String) -> Bool {
            if let targetID, collected[targetID] == nil, SlackInterpreter.rowPrecedes(targetID, oldest) { return true }
            if request.whole { return true }
            if let last = request.last, collected.count < last { return true }
            if let text = request.containing,
               !collected.values.contains(where: { SlackInterpreter.isPagingMessageRow($0) && contains($0, text: text) }) {
                return true
            }
            return false
        }

        mutating func remember(_ observation: SlackInterpreter.HistoryObservation) {
            retainUnrecognised(observation)
            keep(observation.rows)
        }

        mutating func retainUnrecognised(_ observation: SlackInterpreter.HistoryObservation) {
            for row in observation.rows where SlackInterpreter.isUnrecognisedMessageRow(row) {
                guard let id = row.domID else { continue }
                guard let existing = unrecognised[id] else {
                    unrecognised[id] = row
                    continue
                }
                let previous = SlackInterpreter.plainText(existing)
                let additions = SlackInterpreter.plainText(row).filter { !previous.contains($0) }
                if additions.isEmpty { continue }
                unrecognised[id] = Node(role: "AXGroup", domID: id, domClasses: row.domClasses,
                    children: (previous + additions).map { Node(role: "AXStaticText", value: $0) })
            }
        }

        private mutating func keep(_ rows: [Node]) {
            for row in rows {
                guard let id = row.domID else { continue }
                if let existing = collected[id] {
                    let wasUnknown = SlackInterpreter.isUnrecognisedMessageRow(existing)
                    let isUnknown = SlackInterpreter.isUnrecognisedMessageRow(row)
                    if !wasUnknown && isUnknown { continue }
                    // Geometry only breaks ties between equally interpretable versions.
                    if wasUnknown == isUnknown, SlackInterpreter.isOnScreen(existing),
                       !SlackInterpreter.isOnScreen(row) { continue }
                }
                collected[id] = row
            }
        }
    }
}
