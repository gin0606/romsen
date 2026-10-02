import AXTree
import Testing

@testable import SlackAdapter

/// A message list that renders only a window of its rows, like Slack's virtual list.
private final class FakeSlack {
    let ids: [String]
    var visible: Range<Int>
    var scrolls = 0
    /// The id of the row whose thread is showing in the thread pane.
    var openThread: String?
    var presses: [String] = []
    var texts: [String: String] = [:]
    var pane = SlackHistory.Pane.conversation

    init(count: Int, visible: Range<Int>) {
        ids = (0..<count).map { "message-list_17000000\(String(format: "%02d", $0)).000000" }
        self.visible = visible
    }

    var driver: SlackHistory.Driver {
        SlackHistory.Driver(
            snapshot: { [self] in
                let rows = ids[visible].map { id in
                    Node(
                        role: "AXGroup", domID: id, domClasses: ["c-virtual_list__item"],
                        children: [
                            Node(
                                role: "AXGroup", domClasses: ["c-message_kit__hover"],
                                children: [Node(role: "AXStaticText", value: texts[id] ?? "text")])
                        ])
                }
                var listRows = rows
                if pane == .thread, visible.lowerBound == 0 {
                    listRows.append(Node(role: "AXGroup", domID: "thread_separator"))
                }
                let list = Node(role: "AXList", children: listRows)
                var views = pane == .thread
                    ? [Node(role: "AXGroup", domClasses: ["p-view_contents--secondary"], children: [list])]
                    : [list]
                if let openThread {
                    let root = Node(
                        role: "AXGroup", domID: "thread_" + openThread.dropFirst("message-list_".count),
                        domClasses: ["c-virtual_list__item"],
                        children: [Node(role: "AXGroup", domClasses: ["c-message_kit__hover"])])
                    views.append(Node(role: "AXGroup", domClasses: ["p-view_contents--secondary"], children: [root]))
                }
                return [Node(role: "AXWindow", children: views)]
            },
            scrollToVisible: { [self] id in
                guard let index = ids.firstIndex(of: id), visible.contains(index) else { return false }
                scrolls += 1
                let shift = index == visible.lowerBound ? -3 : index == visible.upperBound - 1 ? 3 : 0
                let lower = min(max(visible.lowerBound + shift, 0), ids.count - visible.count)
                visible = lower..<(lower + visible.count)
                return true
            },
            pause: {},
            press: { [self] id, descendantClass in
                guard let index = ids.firstIndex(of: id), visible.contains(index) else { return false }
                presses.append(descendantClass)
                openThread = id
                return true
            })
    }
}

private func request(
    olderPages: Int = 0, target: String? = nil, last: Int? = nil, containing: String? = nil
) -> SlackHistory.Request {
    var request = SlackHistory.Request()
    request.olderPages = olderPages
    request.target = target
    request.last = last
    request.containing = containing
    return request
}

private func ids(_ windows: [Node]) -> [String] {
    windows[0].children[0].children.compactMap(\.domID)
}

@Test func collectsOlderRowsInOrderAndScrollsBack() throws {
    let slack = FakeSlack(count: 20, visible: 15..<20)

    let windows = try SlackHistory.collect(request(olderPages: 2), driver: slack.driver)

    #expect(ids(windows) == Array(slack.ids[9..<20]))
    #expect(slack.visible == 15..<20)
}

@Test func stopsAtTheStartOfTheConversation() throws {
    let slack = FakeSlack(count: 8, visible: 3..<8)

    let windows = try SlackHistory.collect(request(olderPages: 5), driver: slack.driver)

    #expect(ids(windows) == slack.ids)
    #expect(slack.visible == 3..<8)
}

@Test func leavesSlackUntouchedWithoutPages() throws {
    let slack = FakeSlack(count: 20, visible: 15..<20)

    let windows = try SlackHistory.collect(request(olderPages: 0), driver: slack.driver)

    #expect(ids(windows) == Array(slack.ids[15..<20]))
    #expect(slack.scrolls == 0)
}

private func timestamp(_ id: String) -> String {
    String(id.dropFirst("message-list_".count))
}

@Test func scrollsUpUntilTheTargetIsRenderedThenScrollsBack() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)

    let windows = try SlackHistory.collect(request(olderPages: 0, target: timestamp(slack.ids[12])), driver: slack.driver)

    // Stops one scroll past the target so that it has messages before it.
    #expect(ids(windows) == Array(slack.ids[7..<30]))
    #expect(slack.visible == 25..<30)
}

@Test func scrollsDownToATargetNewerThanTheRenderedRows() throws {
    let slack = FakeSlack(count: 30, visible: 5..<10)

    let windows = try SlackHistory.collect(request(olderPages: 0, target: timestamp(slack.ids[20])), driver: slack.driver)

    #expect(ids(windows).contains(slack.ids[20]))
    #expect(ids(windows).first == slack.ids[5])
}

@Test func doesNotScrollWhenTheTargetIsAlreadyRendered() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)

    let windows = try SlackHistory.collect(request(olderPages: 0, target: timestamp(slack.ids[27])), driver: slack.driver)

    #expect(ids(windows) == Array(slack.ids[25..<30]))
    #expect(slack.scrolls == 0)
}

@Test func givesUpSearchingAtTheStartOfTheConversation() throws {
    let slack = FakeSlack(count: 12, visible: 7..<12)

    let windows = try SlackHistory.collect(request(olderPages: 0, target: "1600000000.000000"), driver: slack.driver)

    #expect(ids(windows) == slack.ids)
    #expect(slack.visible == 7..<12)
}

@Test func opensTheThreadOfAMessageThatHasScrolledAway() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)

    #expect(try SlackHistory.openThread(root: timestamp(slack.ids[12]), driver: slack.driver))
    #expect(slack.openThread == slack.ids[12])
    #expect(slack.presses == ["c-message__reply_count"])
    #expect(slack.visible == 25..<30)
}

@Test func doesNotClickWhenTheThreadIsAlreadyOpen() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)
    slack.openThread = slack.ids[12]

    #expect(try SlackHistory.openThread(root: timestamp(slack.ids[12]), driver: slack.driver))
    #expect(slack.presses.isEmpty)
    #expect(slack.scrolls == 0)
}

@Test func reportsAThreadWhoseMessageCannotBeFound() throws {
    let slack = FakeSlack(count: 12, visible: 7..<12)

    #expect(try !SlackHistory.openThread(root: "1600000000.000000", driver: slack.driver))
    #expect(slack.presses.isEmpty)
}

@Test func readsBackOnlyFarEnoughForTheNewestMessages() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)

    let windows = try SlackHistory.collect(request(last: 7), driver: slack.driver)

    #expect(ids(windows) == Array(slack.ids[23..<30]))
    #expect(slack.visible == 25..<30)
}

@Test func trimsToTheNewestMessagesWithoutScrollingWhenEnoughAreRendered() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)

    let windows = try SlackHistory.collect(request(last: 2), driver: slack.driver)

    #expect(ids(windows) == Array(slack.ids[28..<30]))
    #expect(slack.scrolls == 0)
}

@Test func readsBackUntilAMessageContainsTheText() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)
    slack.texts[slack.ids[17]] = "The Needle is here"

    let windows = try SlackHistory.collect(request(containing: "needle"), driver: slack.driver)

    // Stops one scroll past the match so that it has messages before it.
    #expect(ids(windows) == Array(slack.ids[13..<30]))
    #expect(slack.visible == 25..<30)
}


@Test func readsTheWholeThreadAndReturnsToItsNewestRows() throws {
    let slack = FakeSlack(count: 14, visible: 9..<14)
    slack.pane = .thread
    var request = request()
    request.pane = .thread
    request.whole = true

    let windows = try SlackHistory.collect(request, driver: slack.driver)

    #expect(SlackHistory.messageRows(.thread, in: windows).compactMap(\.domID) == slack.ids)
    #expect(slack.visible == 9..<14)
    #expect(slack.scrolls == 7) // Three pages up, three down, then make the newest row visible.
}

private func observation(_ numbers: Range<Int>, atStart: Bool = false, roots: Set<String> = [])
    -> SlackInterpreter.HistoryObservation {
    SlackInterpreter.HistoryObservation(
        rows: numbers.map {
            Node(role: "AXGroup", domID: "message-list_17000000\(String(format: "%02d", $0)).000000")
        }, atThreadStart: atStart, openThreadRoots: roots)
}

@Test func plansOlderPagesAndRestorationFromObservations() {
    let start = observation(10..<15)
    let older = observation(7..<12)
    var plan = SlackHistory.Plan(request(olderPages: 1), observation: start)
    let oldest = start.rows.first!.domID!
    let newest = older.rows.last!.domID!
    #expect(plan.next() == .scroll(oldest, .older(oldest)))
    #expect(plan.next(after: older) == .scroll(newest, .newer(newest)))
    #expect(plan.next(after: start) == .scroll(start.rows.last!.domID!, nil))
    #expect(plan.next() == .done)
    #expect(plan.mergedRows.compactMap(\.domID) == observation(7..<15).rows.compactMap(\.domID))
}

@Test func endsTheSearchWhenWaitingFindsNoOlderRows() {
    let start = observation(10..<15)
    var plan = SlackHistory.Plan(request(target: "1600000000.000000"), observation: start)
    #expect(plan.next() == .scroll(start.rows.first!.domID!, .older(start.rows.first!.domID!)))
    #expect(plan.next(after: nil) == .done)
}

@Test func limitsSearchScrollsAndStillRestoresTheList() {
    var request = request()
    request.whole = true
    request.scrollLimit = 2
    let start = observation(10..<15)
    let first = observation(7..<12)
    let second = observation(4..<9)
    var plan = SlackHistory.Plan(request, observation: start)
    #expect(plan.next() == .scroll(start.rows.first!.domID!, .older(start.rows.first!.domID!)))
    #expect(plan.next(after: first) == .scroll(first.rows.first!.domID!, .older(first.rows.first!.domID!)))
    #expect(plan.next(after: second) == .scroll(second.rows.last!.domID!, .newer(second.rows.last!.domID!)))
    #expect(plan.next(after: first) == .scroll(first.rows.last!.domID!, .newer(first.rows.last!.domID!)))
    #expect(plan.next(after: start) == .scroll(start.rows.last!.domID!, nil))
    #expect(plan.next() == .done)
}

@Test func threadStartObservationStopsBeforeAnotherScroll() {
    var request = request()
    request.pane = .thread
    request.whole = true
    let start = observation(0..<5, atStart: true)
    var plan = SlackHistory.Plan(request, observation: start)
    #expect(plan.next() == .observe)
    #expect(plan.next(after: start) == .done)
}

@Test func preservesTheOnScreenVersionWhenLaterRowsAreClipped() {
    var start = observation(10..<15)
    start.rows[0].frame = .init(x: 0, y: 0, width: 100, height: 20)
    start.rows[0].value = "visible text"
    var older = observation(7..<12)
    older.rows[3].frame = .init(x: 0, y: 0, width: 100, height: 1)
    older.rows[3].value = "clipped text"
    var plan = SlackHistory.Plan(request(olderPages: 1), observation: start)
    _ = plan.next()
    _ = plan.next(after: older)
    #expect(plan.mergedRows.first { $0.domID == start.rows[0].domID } == start.rows[0])
}

@Test func plansTheReplyClickRestorationAndThreadConfirmation() {
    let start = observation(10..<15)
    let found = observation(7..<12)
    let root = timestamp(found.rows[0].domID!)
    var plan = SlackHistory.Plan(request(target: root), observation: start, openingThread: root)
    #expect(plan.next() == .scroll(start.rows[0].domID!, .older(start.rows[0].domID!)))
    #expect(plan.next(after: found) == .press(found.rows[0].domID!))
    #expect(plan.next(succeeded: true) == .scroll(found.rows[0].domID!, .older(found.rows[0].domID!)))
    #expect(plan.next(after: nil) == .scroll(found.rows.last!.domID!, .newer(found.rows.last!.domID!)))
    #expect(plan.next(after: start) == .scroll(start.rows.last!.domID!, nil))
    #expect(plan.next() == .waitForThread(root))
    #expect(plan.next(after: observation(10..<15, roots: [root])) == .done)
    #expect(plan.threadOpened)
}

@Test func reportsAReplyClickOrThreadConfirmationThatFails() {
    let start = observation(10..<15)
    let root = timestamp(start.rows[2].domID!)
    var failedClick = SlackHistory.Plan(request(target: root), observation: start, openingThread: root)
    #expect(failedClick.next() == .press(start.rows[2].domID!))
    #expect(failedClick.next(succeeded: false) == .done)
    #expect(!failedClick.threadOpened)
    var failedWait = SlackHistory.Plan(request(target: root), observation: start, openingThread: root)
    #expect(failedWait.next() == .press(start.rows[2].domID!))
    #expect(failedWait.next(succeeded: true) == .waitForThread(root))
    #expect(failedWait.next(after: nil) == .done)
    #expect(!failedWait.threadOpened)
}


@Test func leavesAnUnidentifiableListUntouchedEvenWhenTheTargetIsRendered() throws {
    let start = observation(10..<15)
    var rows = start.rows
    rows[rows.count - 1].domID = nil
    rows[rows.count - 1].domClasses = ["c-virtual_list__item"]
    rows[rows.count - 1].children = [Node(role: "AXGroup", domClasses: ["c-message_kit__hover"])]
    for index in rows.indices.dropLast() {
        rows[index].domClasses = ["c-virtual_list__item"]
        rows[index].children = [Node(role: "AXGroup", domClasses: ["c-message_kit__hover"])]
    }
    let windows = [Node(role: "AXWindow", children: [Node(role: "AXList", children: rows)])]
    var actions = 0
    let driver = SlackHistory.Driver(snapshot: { windows }, scrollToVisible: { _ in actions += 1; return true }, pause: {})
    let result = try SlackHistory.collect(request(target: timestamp(rows[0].domID!)), driver: driver) { _ in actions += 1 }
    #expect(result == windows)
    #expect(actions == 0)
}

@Test(arguments: [false, true])
func waitsForTheRequestedThreadEvenWhileAnotherThreadIsOpen(appears: Bool) throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)
    slack.openThread = slack.ids[0]
    let target = slack.ids[27]
    var pauses = 0
    var driver = slack.driver
    driver.press = { _, _ in true }
    driver.pause = {
        pauses += 1
        if appears, pauses == 3 { slack.openThread = target }
    }

    #expect(try SlackHistory.openThread(root: timestamp(target), driver: driver) == appears)
    #expect(pauses == (appears ? 3 : 10))
    #expect(slack.scrolls == 0)
}

@Test func notifiesOnceWhileTheSearchedTargetIsRenderedThenRestoresTheList() throws {
    let slack = FakeSlack(count: 30, visible: 25..<30)
    let target = slack.ids[12]
    var notified: [String] = []
    let windows = try SlackHistory.collect(request(target: timestamp(target)), driver: slack.driver) { id in
        #expect(slack.ids[slack.visible].contains(id))
        notified.append(id)
    }
    #expect(notified == [target])
    #expect(ids(windows) == Array(slack.ids[7..<30]))
    #expect(slack.visible == 25..<30)
}
