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
                var views = [Node(role: "AXList", children: rows)]
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
