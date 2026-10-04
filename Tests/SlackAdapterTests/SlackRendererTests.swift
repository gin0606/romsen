import AXTree
import Foundation
import Testing

@testable import SlackAdapter

private func text(_ value: String) -> Node {
    Node(role: "AXStaticText", value: value)
}

private func message(id: String, sender: String?, body: [Node], extras: [Node] = []) -> Node {
    var header: [Node] = []
    if let sender {
        header.append(Node(role: "AXButton", title: sender, domClasses: ["c-message__sender_button"]))
        header.append(Node(role: "AXImage", description: "clock emoji"))
    }
    header.append(Node(role: "AXLink", description: "Today 12:00:00 ", domClasses: ["c-timestamp"], children: [text("12:00")]))
    let content = header + [Node(role: "AXGroup", domClasses: ["p-rich_text_section"], children: body)] + extras
    return Node(
        role: "AXGroup", domID: id, domClasses: ["c-virtual_list__item"],
        children: [Node(role: "AXGroup", domClasses: ["c-message_kit__hover"], children: content)])
}

private func window(views: [Node]) -> Node {
    Node(
        role: "AXWindow",
        children: [
            Node(role: "AXGroup", description: "Acme", domClasses: ["p-client_workspace_wrapper"], children: views)
        ])
}

private let utc = TimeZone(identifier: "UTC")!

@Test func rendersMessagesWithSenderTimeThreadAndReactions() {
    let reactions = Node(
        role: "AXGroup", domClasses: ["c-reaction_bar"],
        children: [
            Node(role: "AXCheckBox", domClasses: ["c-reaction"], children: [Node(role: "AXImage", description: "pray emoji"), text("2")]),
            Node(role: "AXButton", description: "Add reaction...", domClasses: ["c-reaction_add"]),
        ])
    let replies = Node(role: "AXButton", title: "4 replies", domClasses: ["c-message__reply_count"])
    let replyBar = Node(role: "AXGroup", domClasses: ["c-message__reply_bar_description"], children: [text("View thread")])
    let mention = Node(role: "AXLink", description: "@bob", children: [text("@bob")])
    let link = Node(role: "AXLink", description: "example.com", children: [text("example.com")])
    let footer = Node(role: "AXButton", title: "See new replies", domClasses: ["c-message__broadcast_footer"])
    let hoverActions = Node(
        role: "AXGroup", domClasses: ["c-message_actions__container"],
        children: [Node(role: "AXCheckBox", children: [Node(role: "AXImage", description: "eyes emoji")])])
    let view = Node(
        role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents", "p-view_contents--primary"],
        children: [
            message(
                id: "message-list_1700000000.000100", sender: "alice",
                body: [
                    mention, link, text("first line"), text("second line"), Node(role: "AXImage", description: "bow emoji"),
                    text(" "), text("(edited)"),
                ],
                extras: [reactions, replies, replyBar, footer, hoverActions]),
            message(id: "message-list_1700000060.000200", sender: nil, body: [text("follow-up")]),
        ])

    #expect(
        render([window(views: [view])], timeZone: utc) == """
            # Slack: Acme

            ## Channel general
            [2023-11-14 22:13] alice: @bob example.com first line
              second line:bow: (edited)
              reactions: :pray: 2
              thread: 4 replies
            [2023-11-14 22:14] alice: follow-up
            """)
}

private func plain(id: String, _ body: String) -> Node {
    message(id: id, sender: "alice", body: [text(body)])
}

@Test func leavesOutTheSidebar() {
    let sidebar = Node(
        role: "AXGroup", description: "Home", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
        children: [Node(role: "AXRow", description: "general")])
    let view = Node(
        role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents"],
        children: [plain(id: "message-list_1700000000.000100", "hello")])

    #expect(
        render([window(views: [sidebar, view])], timeZone: utc) == """
            # Slack: Acme

            ## Channel general
            [2023-11-14 22:13] alice: hello
            """)
}

@Test func focusPrintsOnlyTheLinkedMessageAndItsNeighbours() {
    let channel = Node(
        role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents"],
        children: (0..<5).map { plain(id: "message-list_170000000\($0).000000", "channel \($0)") })
    let thread = Node(
        role: "AXGroup", description: "Thread", domClasses: ["p-view_contents", "p-view_contents--secondary"],
        children: (5..<8).map { plain(id: "thread-list_170000000\($0).000000", "reply \($0)") })
    let windows = [window(views: [channel, thread])]

    #expect(
        render(windows, focus: .init(timestamp: "1700000003.000000", context: 1), timeZone: utc) == """
            # Slack: Acme

            ## Channel general
            [2023-11-14 22:13] alice: channel 2
            >> [2023-11-14 22:13] alice: channel 3
            [2023-11-14 22:13] alice: channel 4
            """)
    #expect(
        render(windows, focus: .init(timestamp: "1700000005.000000", context: 1), timeZone: utc) == """
            # Slack: Acme

            ## Thread
            >> [2023-11-14 22:13] alice: reply 5
            [2023-11-14 22:13] alice: reply 6
            """)
    #expect(
        render(
            windows, focus: .init(timestamp: "1700000005.000000", context: 1, wholeThread: true), timeZone: utc) == """
            # Slack: Acme

            ## Thread
            >> [2023-11-14 22:13] alice: reply 5
            [2023-11-14 22:13] alice: reply 6
            [2023-11-14 22:13] alice: reply 7
            """)
    #expect(
        render(windows, only: .thread, timeZone: utc) == """
            # Slack: Acme

            ## Thread
            [2023-11-14 22:13] alice: reply 5
            [2023-11-14 22:13] alice: reply 6
            [2023-11-14 22:13] alice: reply 7
            """)
    #expect(SlackInterpreter.contains(.thread, in: windows, timestamp: "1700000006.000000"))
    #expect(!SlackInterpreter.contains(.thread, in: windows, timestamp: "1700000009.000000"))
    #expect(!SlackInterpreter.contains(.conversation, in: windows, timestamp: "1700000006.000000"))
}

@Test func readsTheOpenConversationFromTheDateDivider() {
    let divider = Node(role: "AXGroup", domID: "message-list_1700000000000.C0123ABC", domClasses: ["c-virtual_list__item"])
    let list = Node(role: "AXList", children: [divider, plain(id: "message-list_1700000000.000100", "hello")])

    #expect(SlackInterpreter.openChannelID([window(views: [list])]) == "C0123ABC")
    #expect(SlackInterpreter.openChannelID([window(views: [])]) == nil)
}

@Test(arguments: [
    "message-list_Thread_separator", "message-list_Thread_input",
    "message-list_Thread_1700000000.000100_separator",
    "message-list_1700000000.000100", "message-list_.C123",
    "message-list_1700000000000.", "message-list_1700000000000..C123",
    "message-list_1700000000000.C123.extra", "message-list_invalid.C123",
    "message-list_1700000000000x.C123", "other-list_1700000000000.C123"
])
func ignoresRowsThatAreNotDateDividersWhenReadingTheConversationID(id: String) {
    let row = Node(role: "AXGroup", domID: id)
    let list = Node(role: "AXList", children: [row, plain(id: "message-list_1700000000.000100", "hello")])
    #expect(SlackInterpreter.openChannelID([window(views: [list])]) == nil)
}

@Test func parsesMessageLinks() {
    let link = SlackLink("https://acme.slack.com/archives/C0123ABC/p1700000000000100?thread_ts=1699999999.000000&cid=C0123ABC")

    #expect(link?.channelID == "C0123ABC")
    #expect(link?.timestamp == "1700000000.000100")
    #expect(link?.threadTimestamp == "1699999999.000000")
    #expect(SlackLink("https://acme.slack.com/archives/C0123ABC/p1700000000000100")?.threadTimestamp == nil)
    #expect(SlackLink("https://acme.slack.com/archives/C0123ABC") == nil)
    #expect(SlackLink("https://example.com/archives/C0123ABC/p1700000000000100") == nil)
    #expect(SlackLink("https://acme.slack.com/archives/C0123ABC/pabc") == nil)
}

@Test func fallsBackToPlainTextForUnrecognisedViews() {
    let view = Node(
        role: "AXGroup", description: "Something new", domClasses: ["p-view_contents"],
        children: [Node(role: "AXGroup", children: [text("hello"), Node(role: "AXButton", title: "Open")])])

    #expect(
        render([window(views: [view])], timeZone: utc) == """
            # Slack: Acme

            ## Something new
            hello
            Open
            """)
}

/// A node placed on screen: `line` is the row of text it starts on, and `lines` how many it spans.
private func placed(_ node: Node, x: ClosedRange<Double>, line: Int, lines: Int = 1) -> Node {
    var node = node
    node.frame = CGRect(x: x.lowerBound, y: Double(line) * 22, width: x.upperBound - x.lowerBound, height: Double(lines) * 20)
    return node
}

private func section(_ children: [Node]) -> Node {
    placed(Node(role: "AXGroup", domClasses: ["p-rich_text_section"], children: children), x: 0...500, line: 0, lines: 4)
}

private func body(of content: [Node]) -> String {
    let row = Node(
        role: "AXGroup", domID: "message-list_1700000000.000100", domClasses: ["c-virtual_list__item"],
        children: [
            Node(
                role: "AXGroup", domClasses: ["c-message_kit__hover"],
                children: [Node(role: "AXButton", title: "alice", domClasses: ["c-message__sender_button"])] + content)
        ])
    let view = Node(role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents"], children: [row])
    let output = render([window(views: [view])], timeZone: utc)
    return String(output.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: true)[2])
}

private func link(_ label: String) -> Node {
    Node(role: "AXLink", description: label, children: [text(label)])
}

@Test func readsLineBreaksAndSpacesFromWhereThePiecesSit() {
    let code = Node(role: "AXGroup", domClasses: ["c-mrkdwn__code"], children: [text("/run")])

    // Mentions on their own line, then text on the next one.
    #expect(
        body(of: [
            section([
                placed(link("@bob"), x: 0...40, line: 0), placed(link("@carol"), x: 42...90, line: 0),
                placed(text("see below"), x: 0...300, line: 1),
            ])
        ]) == """
            [2023-11-14 22:13] alice: @bob @carol
              see below
            """)
    // A quote mark touching a mention, and a gap between the mention and the code.
    #expect(
        body(of: [
            section([
                placed(text("reminder: \""), x: 0...80, line: 0), placed(link("@bob"), x: 80...120, line: 0),
                placed(code, x: 123...160, line: 0), placed(text("\""), x: 160...165, line: 0),
            ])
        ]) == "[2023-11-14 22:13] alice: reminder: \"@bob `/run`\"")
    // Wrapped text followed by a link on its last line stays one paragraph.
    #expect(
        body(of: [
            section([placed(text("long text ( "), x: 0...500, line: 0, lines: 2), placed(link("example.com"), x: 100...200, line: 1)])
        ]) == "[2023-11-14 22:13] alice: long text ( example.com")
    // A mention that did not fit at the end of the line wraps without a break.
    #expect(
        body(of: [
            section([placed(text("almost full line "), x: 0...480, line: 0), placed(link("@bob"), x: 0...40, line: 1)])
        ]) == "[2023-11-14 22:13] alice: almost full line @bob")
}

@Test func quotesSharedMessagesAndNamesAttachedFiles() {
    let shared = Node(
        role: "AXGroup", domClasses: ["c-message_attachment"],
        children: [
            placed(Node(role: "AXButton", title: "dave", children: [placed(text("dave"), x: 0...30, line: 2)]), x: 0...30, line: 2),
            placed(link("Aug 25"), x: 34...80, line: 2),
            section([placed(text("the original words"), x: 0...200, line: 3)]),
            Node(role: "AXGroup", domClasses: ["c-message_kit__file"], children: [text("Zip")]),
            Node(role: "AXGroup", description: "data.zip", domClasses: ["c-pillow_file_container"], children: [text("data.zip"), text("Zip")]),
        ])

    #expect(
        body(of: [section([placed(text("look at this"), x: 0...100, line: 0)]), shared]) == """
            [2023-11-14 22:13] alice: look at this
              > dave Aug 25
              > the original words
              > [file: data.zip]
            """)
}

@Test func usesHorizontalPositionsForRowsOutsideTheViewport() {
    func clipped(_ node: Node, x: ClosedRange<Double>) -> Node {
        var node = node
        node.frame = CGRect(x: x.lowerBound, y: 150, width: x.upperBound - x.lowerBound, height: 1)
        return node
    }
    let code = Node(role: "AXGroup", domClasses: ["c-mrkdwn__code"], children: [text("/run")])

    #expect(
        body(of: [
            clipped(text("reminder: \""), x: 0...80), clipped(link("@bob"), x: 80...120), clipped(code, x: 123...160),
            clipped(text("\""), x: 160...165), clipped(text("next line"), x: 0...70),
        ]) == """
            [2023-11-14 22:13] alice: reminder: "@bob `/run`"
              next line
            """)
}

@Test func rendersSearchResultsWithTheirQueryAndLocation() {
    let result = Node(
        role: "AXGroup", domID: "53a36a2c", domClasses: ["listitem__iBnNh"],
        children: [
            Node(
                role: "AXGroup", domClasses: ["c-message_kit__hover"],
                children: [
                    Node(role: "AXButton", title: "alice", domClasses: ["c-message__sender_button"]),
                    Node(role: "AXImage", description: "palm tree emoji"),
                    text("in "),
                    Node(role: "AXGroup", domClasses: ["c-inline_channel_entity"], children: [text("general")]),
                    Node(role: "AXLink", description: "Sep 24 01:10", domClasses: ["c-timestamp"], children: [text("Sep 24 01:10")]),
                    Node(role: "AXGroup", domClasses: ["p-rich_text_section"], children: [text("found it")]),
                ])
        ])
    let search = Node(
        role: "AXGroup", description: "Search", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
        children: [
            Node(role: "AXGroup", domClasses: ["headerContainer__z6rzo"], children: [text("Results for: "), text("from:@alice")]),
            Node(role: "AXGroup", domClasses: ["resultCounts__aD8i3"], children: [text("12 results")]),
            Node(role: "AXList", children: [result]),
        ])

    #expect(
        render([window(views: [search])], timeZone: utc) == """
            # Slack: Acme

            ## Search
            Results for: from:@alice
            12 results
            [Sep 24 01:10] alice (in general): found it
            """)
}

@Test func takesTheSenderFromTheRowLabelWhenTheFirstRowOmitsIt() {
    var row = message(id: "message-list_1700000000.000100", sender: nil, body: [text("continued")])
    row.title = "alice : continued. 22:13."
    let view = Node(role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents"], children: [row])

    #expect(
        render([window(views: [view])], timeZone: utc) == """
            # Slack: Acme

            ## Channel general
            [2023-11-14 22:13] alice: continued
            """)
}

private func render(
    _ windows: [Node], focus: SlackRenderer.Focus? = nil, only: SlackHistory.Pane? = nil, timeZone: TimeZone
) -> String {
    SlackRenderer.render(SlackInterpreter.read(windows), focus: focus, only: only, timeZone: timeZone)
}

@Test func interpretsViewsAndBodyBlocksWithoutOutputMarkers() throws {
    let shared = Node(role: "AXGroup", domClasses: ["c-message_attachment"], children: [
        text("quoted words"),
        Node(role: "AXGroup", description: "data.zip", domClasses: ["c-pillow_file_container"]),
    ])
    let view = Node(role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents"], children: [
        message(id: "message-list_1700000000.000100", sender: "alice", body: [text("hello")], extras: [
            Node(role: "AXGroup", description: "outer.zip", domClasses: ["c-pillow_file_container"]),
            text("after file"), shared, text("after quote"),
        ]),
        Node(role: "AXTextArea", value: "  unsent draft\n", domClasses: ["ql-editor"]),
    ])
    let unknown = Node(role: "AXGroup", description: "New view", domClasses: ["p-view_contents"], children: [text("visible")])
    let screens = SlackInterpreter.read([window(views: [view, unknown])])
    let screen = try #require(screens.first)
    #expect(screen.workspace == "Acme")
    #expect(screen.views.map(\.kind) == [.conversation, .unknown])
    #expect(screen.views[0].title == "Channel general")
    #expect(screen.views[0].draft == "unsent draft")
    #expect(screen.views[1].plainText == ["visible"])
    let parsed = try #require(screen.views[0].messages.first)
    #expect(parsed.sender == "alice")
    #expect(parsed.timestamp == "1700000000.000100")
    #expect(parsed.sentDate == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(parsed.body == [
        .paragraph([.text("hello")]), .file("outer.zip"), .paragraph([.text("after file")]),
        .quote([.paragraph([.text("quoted words")]), .file("data.zip")]), .paragraph([.text("after quote")]),
    ])
    #expect(SlackRenderer.render(screens, timeZone: utc) == """
        # Slack: Acme

        ## Channel general
        [2023-11-14 22:13] alice: hello
          [file: outer.zip]
          after file
          > quoted words
          > [file: data.zip]
          after quote

        draft in composer: unsent draft

        ## New view
        visible
        """)
}

@Test func fillsOmittedSendersAfterFocusFiltering() {
    var continued = message(id: "message-list_1700000060.000100", sender: nil, body: [text("continued")])
    continued.title = "bob : continued"
    let view = Node(role: "AXGroup", description: "Channel general", domClasses: ["p-view_contents"], children: [
        plain(id: "message-list_1700000000.000100", "previous"), continued,
    ])
    let screens = SlackInterpreter.read([window(views: [view])])
    #expect(screens[0].views[0].messages[1].sender == nil)
    #expect(screens[0].views[0].messages[1].labelledSender == "bob")
    #expect(SlackRenderer.render(screens, focus: .init(timestamp: "1700000060.000100", context: 0), timeZone: utc) == """
        # Slack: Acme

        ## Channel general
        >> [2023-11-14 22:14] bob: continued
        """)
    #expect(SlackRenderer.render(screens, timeZone: utc).hasSuffix("[2023-11-14 22:14] alice: continued"))
}

@Test func preservesInlineControlsAndSearchHeaderFallback() throws {
    let timestamp = Node(role: "AXLink", description: "Sep 24 01:10", domClasses: ["c-timestamp"])
    let origin = Node(role: "AXLink", title: "original thread", domClasses: ["c-message__broadcast_preamble_link"])
    let content = Node(role: "AXGroup", domClasses: ["c-message_kit__hover"], children: [
        Node(role: "AXButton", title: "alice", domClasses: ["c-message__sender_button"]),
        text("in "), Node(role: "AXButton", title: "general"), timestamp,
        text("reply to"), origin, text("continued"), Node(role: "AXButton", title: "unknown control"),
    ])
    let row = Node(role: "AXGroup", domID: "search-result", children: [content])
    let view = Node(role: "AXGroup", description: "Search", domClasses: ["p-view_contents", "p-view_contents--sidebar"], children: [row])
    let screens = SlackInterpreter.read([window(views: [view])])
    let parsed = try #require(screens[0].views[0].messages.first)
    #expect(parsed.location == [.paragraph([.text("in "), .button("general")])])
    #expect(parsed.body == [.paragraph([
        .text("reply to "), .threadOrigin("original thread"), .text("\ncontinued"), .button("unknown control"),
    ])])
    #expect(SlackRenderer.render(screens, timeZone: utc) == """
        # Slack: Acme

        ## Search
        [Sep 24 01:10] alice (in [general]): reply to [original thread]
          continued[unknown control]
        """)
}

@Test func formatsParagraphBoundariesFromTheReadingModel() {
    let parsed = SlackMessage(rowID: nil, timestamp: nil, sentDate: nil, timeLabel: "12:00", sender: "alice",
        labelledSender: nil, location: [], body: [.paragraph([.text("first")]), .paragraph([.text("second")])],
        replies: nil, reactions: [])
    let view = SlackView(title: "Channel general", kind: .conversation, searchSummary: [], messages: [parsed], draft: nil, plainText: [])
    #expect(SlackRenderer.render([SlackScreen(workspace: nil, views: [view])], timeZone: utc) == """
        # Slack

        ## Channel general
        [12:00] alice: first
          second
        """)
}

@Test func preservesCodeAsSemanticContentAndRendersItsWhitespaceAndBackticks() throws {
    let source = "a  b`c"
    let code = Node(role: "AXGroup", domClasses: ["c-mrkdwn__code"], children: [text("a"), text("  "), text("b`c")])
    let row = message(id: "message-list_1700000000.000100", sender: "example", body: [code])
    let screens = SlackInterpreter.read([Node(role: "AXWindow", children: [
        Node(role: "AXGroup", domClasses: ["p-view_contents"], children: [row])
    ])])
    let parsed = try #require(screens.first?.views.first?.messages.first)
    #expect(parsed.body == [.paragraph([.code(source)])])
    #expect(SlackRenderer.render(screens).contains(": ``a  b`c``"))
}

@Test func preservesCodeInsideQuotesAndKeepsProseNormalisation() {
    let message = SlackMessage(location: [], body: [
        .paragraph([.text("  run   "), .code("/run"), .text("   next  ")]),
        .quote([.paragraph([.code("line  one\n\n  `two`")])]),
        .paragraph([.code("`edge`"), .text("   "), .code(" leading  ")]),
        .paragraph([.code("  ")])
    ], reactions: [])
    let view = SlackView(kind: .conversation, searchSummary: [], messages: [message], plainText: [])
    let output = SlackRenderer.render([SlackScreen(views: [view])])
    #expect(output.contains("run `/run` next"))
    #expect(output.contains("> line  one\n  > \n  >   `two`"))
    #expect(output.contains("`` `edge` `` `  leading   `"))
    #expect(output.hasSuffix("`  `"))
}

@Test func keepsTheAccessibleLabelOfALeafCodeElement() throws {
    let code = Node(role: "AXGroup", title: "  label  ", domClasses: ["c-mrkdwn__code"])
    let row = message(id: "message-list_1700000000.000100", sender: nil, body: [code])
    let screens = SlackInterpreter.read([Node(role: "AXWindow", children: [
        Node(role: "AXGroup", domClasses: ["p-view_contents"], children: [row])
    ])])
    #expect(try #require(screens.first?.views.first?.messages.first).body == [.paragraph([.code("  label  ")])])
}
