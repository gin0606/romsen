import AXTree
import Testing

@testable import SlackAdapter

private let readLink = "https://example.slack.com/archives/C123/p1700000000000100"

private func readRow(_ timestamp: String, text: String) -> Node {
    Node(role: "AXGroup", domID: "message-list_\(timestamp)", domClasses: ["c-virtual_list__item"],
         children: [Node(role: "AXGroup", domClasses: ["c-message_kit__hover"],
                         children: [Node(role: "AXStaticText", value: text)])])
}

private func readScreen(conversation: Bool = true, thread: Bool = true, channel: String? = "C123") -> [Node] {
    let rows = [readRow("1700000000.000100", text: "Needle first"), readRow("1700000001.000100", text: "NEEDLE last")]
    var views: [Node] = []
    if conversation {
        let divider = channel.map { [Node(role: "AXGroup", domID: "message-list_1700000000000.\($0)")] } ?? []
        views.append(Node(role: "AXGroup", domClasses: ["p-view_contents"],
                          children: [Node(role: "AXList", children: divider + rows)]))
    }
    if thread {
        let replies = [readRow("1700000000.000100", text: "root"),
                       readRow("1700000002.000100", text: "Needle reply")]
        views.append(Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--secondary"],
                          children: [Node(role: "AXList", children: replies)]))
    }
    return [Node(role: "AXWindow", children: views)]
}

@Test(arguments: [false, true], [0, 1, 2])
func plansUnlinkedReads(thread: Bool, filter: Int) throws {
    let options = try SlackRead.Options(last: filter == 1 ? 2 : nil, find: filter == 2 ? "needle" : nil,
                                        context: 1, history: 3, thread: thread)
    guard case .read(let request) = try SlackRead.prepare(options, in: readScreen()) else {
        Issue.record("An unlinked read must not open a thread")
        return
    }
    #expect(request.pane == (thread ? .thread : .conversation))
    #expect(request.olderPages == 3)
    #expect(request.last == options.last)
    #expect(request.containing == options.find)
    #expect(request.target == nil)
    #expect(request.whole == (thread && filter == 0))
    let output = try SlackRead.output(options, request: request, in: readScreen())
    #expect(output.only == (thread || filter == 1 ? request.pane : nil))
    let match = thread ? "message-list_1700000002.000100" : "message-list_1700000001.000100"
    #expect(output.focus == (filter == 2 ? .init(row: match, context: 1) : nil))
}

@Test(arguments: [false, true], [false, true])
func plansLinkedReadsAfterOpeningTheirThreadWhenNeeded(thread: Bool, replyLink: Bool) throws {
    let options = try SlackRead.Options(link: readLink + (replyLink ? "?thread_ts=1699999999.000000" : ""),
                                        context: 2, history: 1, thread: thread)
    let action = try SlackRead.prepare(options, in: readScreen())
    let request: SlackHistory.Request
    if thread || replyLink {
        guard case let .openThread(root, planned) = action else {
            Issue.record("Linked thread must open before reading")
            return
        }
        #expect(root == (replyLink ? "1699999999.000000" : "1700000000.000100"))
        #expect(planned.pane == .thread)
        request = planned
    } else {
        guard case .read(let planned) = action else {
            Issue.record("Conversation link must read directly")
            return
        }
        #expect(planned.pane == .conversation)
        request = planned
    }
    #expect(request.target == "1700000000.000100")
    #expect(request.whole == thread)
    #expect(request.olderPages == 1)
    let output = try SlackRead.output(options, request: request, in: readScreen())
    #expect(output.focus == .init(timestamp: "1700000000.000100", context: 2, wholeThread: thread))
    #expect(output.only == nil)
}

@Test func readsTheThreadBesideSearchResultsWithoutAnExplicitThreadFlag() throws {
    let options = try SlackRead.Options()
    var searchRow = readRow("1700000003.000100", text: "search result")
    searchRow.domClasses = []
    let search = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
                      children: [searchRow])
    var windows = readScreen(conversation: false)
    windows[0].children[0].domClasses = ["p-view_contents", "p-view_contents--primary"]
    windows[0].children[0].children.append(Node(role: "AXGroup", domClasses: ["p-threads_flexpane_container"]))
    windows[0].children.append(search)
    guard case .read(let request) = try SlackRead.prepare(options, in: windows) else {
        Issue.record("Expected a read")
        return
    }
    #expect(request.pane == .thread)
    #expect(!request.whole)
    #expect(try SlackRead.output(options, request: request, in: windows).only == nil)
}

@Test func rejectsAnotherConversationAndAllowsAnUnidentifiedConversation() throws {
    let options = try SlackRead.Options(link: readLink, thread: true)
    #expect(throws: SlackRead.Failure.self) {
        try SlackRead.prepare(options, in: readScreen(channel: "C999"))
    }
    guard case .openThread = try SlackRead.prepare(options, in: readScreen(channel: nil)) else {
        Issue.record("An unidentified conversation must not reject a link")
        return
    }
}

@Test(arguments: [false, true])
func allowsAConfirmedThreadOrAnUnconfirmedExistingThread(opened: Bool) throws {
    try SlackRead.afterOpeningThread(root: "1700000000.000100", opened: opened,
                                    in: opened ? [] : readScreen(conversation: false))
}

@Test func reportsMissingThreadsLinksAndMatches() throws {
    #expect(throws: SlackRead.Failure.self) { try SlackRead.Options(link: "invalid") }
    #expect(throws: SlackRead.Failure.self) {
        try SlackRead.prepare(SlackRead.Options(thread: true), in: readScreen(thread: false))
    }
    #expect(throws: SlackRead.Failure.self) {
        try SlackRead.afterOpeningThread(root: "1700000000.000100", opened: false, in: readScreen(thread: false))
    }
    #expect(throws: SlackRead.Failure.self) {
        try SlackRead.output(SlackRead.Options(link: readLink), request: SlackHistory.Request(), in: [])
    }
    do {
        _ = try SlackRead.output(SlackRead.Options(find: "missing"), request: SlackHistory.Request(), in: readScreen())
        Issue.record("A missing search match must fail")
    } catch let error as SlackRead.Failure {
        #expect(error.description == "no message containing \"missing\" was found in the last 2 messages.")
    }
}

@Test func leavesAnEmptyScreenAsAConversationRead() throws {
    guard case .read(let request) = try SlackRead.prepare(SlackRead.Options(), in: []) else {
        Issue.record("Expected a read")
        return
    }
    #expect(request.pane == .conversation)
    #expect(!request.whole)
}

@Test func decidesHowToReachALinkedThread() {
    var windows = readScreen()
    windows[0].children[1].children[0].children.insert(
        Node(role: "AXGroup", domID: "message-list_Thread_separator"), at: 1)
    let open = "1700000000.000100", closed = "1699999999.000000"
    #expect(SlackRead.openingThread(root: closed, in: windows, source: .live)
        == .init(alreadyOpen: false, press: true, rereadIfUnconfirmed: true, startFromThreadRead: true))
    #expect(SlackRead.openingThread(root: open, in: windows, source: .live)
        == .init(alreadyOpen: true, press: false, rereadIfUnconfirmed: true, startFromThreadRead: false))
    #expect(SlackRead.openingThread(root: closed, in: windows, source: .saved)
        == .init(alreadyOpen: false, press: false, rereadIfUnconfirmed: false, startFromThreadRead: false))
    #expect(SlackRead.openingThread(root: open, in: windows, source: .saved)
        == .init(alreadyOpen: true, press: false, rereadIfUnconfirmed: false, startFromThreadRead: false))
}

@Test(arguments: [SlackHistory.Source.live, .saved])
func limitsALinkedTargetToTheRequestedPaneOnlyInASavedTree(source: SlackHistory.Source) throws {
    let options = try SlackRead.Options(link: "https://example.slack.com/archives/C123/p1700000001000100")
    var request = SlackHistory.Request()
    request.pane = .thread
    if source == .live {
        let output = try SlackRead.output(options, request: request, in: readScreen(), source: source)
        #expect(output.only == nil)
    } else {
        #expect(throws: SlackRead.Failure.self) {
            try SlackRead.output(options, request: request, in: readScreen(), source: source)
        }
        let rootLink = try SlackRead.Options(link: readLink)
        #expect(try SlackRead.output(rootLink, request: request, in: readScreen(), source: source).only == .thread)
    }
    let unlinked = try SlackRead.Options(find: "needle")
    #expect(try SlackRead.output(unlinked, request: request, in: readScreen(), source: source).only == nil)
}
