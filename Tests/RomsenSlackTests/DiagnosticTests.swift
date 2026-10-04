import AXTree
import Foundation
import SlackAdapter
import Testing

@testable import RomsenSlack

private func diagnosticRow(_ number: Int, unknown: Bool = false, prefix: String = "message-list_") -> Node {
    Node(role: "AXGroup", domID: prefix + "17000000\(String(format: "%02d", number)).000100",
         domClasses: ["c-virtual_list__item"], children: [
            Node(role: "AXGroup", domClasses: [unknown ? "changed-message" : "c-message_kit__hover"],
                 children: [Node(role: "AXStaticText", value: "\(unknown ? "unknown" : "known") body \(number)")])
         ])
}

private func diagnosticView(_ rows: [Node], thread: Bool = false) -> Node {
    Node(role: "AXGroup", description: thread ? "Thread" : "Conversation",
         domClasses: ["p-view_contents", thread ? "p-view_contents--secondary" : "p-view_contents--primary"],
         children: [Node(role: "AXList", children: rows)])
}

private func diagnosticWindow(_ views: [Node]) -> [Node] {
    [Node(role: "AXWindow", children: views)]
}

private func diagnosticRead(_ windows: [Node], arguments: [String] = []) throws -> (String, [String]) {
    let command = try Slack.parse(arguments)
    var warnings: [String] = []
    let driver = SlackHistory.Driver(snapshot: { windows }, scrollToVisible: { _ in false }, pause: {})
    let output = try command.read(using: driver, warn: { warnings.append($0) })
    return (output, warnings)
}

@Test func preservesMixedRowsAndLimitsDiagnosticsToThePrintedRange() throws {
    let windows = diagnosticWindow([diagnosticView([
        diagnosticRow(0, unknown: true), diagnosticRow(1), diagnosticRow(2, unknown: true), diagnosticRow(3)
    ]), diagnosticView([diagnosticRow(4, unknown: true, prefix: "message-list_Thread_")], thread: true)])
    let (all, warnings) = try diagnosticRead(windows)
    #expect(all.contains("known body 1"))
    #expect(all.contains("unknown body 0"))
    #expect(all.contains("unknown body 2"))
    #expect(all.contains("unknown body 4"))
    #expect(warnings.count == 1)
    let (last, lastWarnings) = try diagnosticRead(windows, arguments: ["--last", "2"])
    #expect(!last.contains("body 0"))
    #expect(!last.contains("body 1"))
    #expect(last.contains("unknown body 2"))
    #expect(last.contains("known body 3"))
    #expect(!last.contains("body 4"))
    #expect(lastWarnings.count == 1)
    let (found, foundWarnings) = try diagnosticRead(windows, arguments: ["--find", "known body 1", "--context", "0"])
    #expect(found.contains("known body 1"))
    #expect(!found.contains("unknown"))
    #expect(foundWarnings.isEmpty)
    let (context, contextWarnings) = try diagnosticRead(windows, arguments: ["--find", "known body 1", "--context", "1"])
    #expect(context.contains("unknown body 0"))
    #expect(context.contains("unknown body 2"))
    #expect(!context.contains("body 3"))
    #expect(contextWarnings.count == 1)
    #expect(try diagnosticRead(windows, arguments: ["--last", "1"]).1.isEmpty)
}

@Test func keepsUnknownRowsSeenWhilePollingEvenIfTheListDoesNotAdvance() throws {
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1), diagnosticRow(2)])])
    let changed = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1, unknown: true), diagnosticRow(2)])])
    var reads = 0
    let driver = SlackHistory.Driver(snapshot: {
        reads += 1
        return reads == 2 ? changed : initial
    }, scrollToVisible: { _ in true }, pause: {})
    let command = try Slack.parse(["--history", "1", "--find", "known body 1", "--context", "0"])
    var warnings: [String] = []
    let output = try command.read(using: driver, warn: { warnings.append($0) })
    #expect(reads > 2)
    #expect(output.contains("known body 1"))
    #expect(output.contains("unknown body 1"))
    #expect(!output.contains("body 0"))
    #expect(warnings.count == 1)
}

@Test func keepsUnknownRowsFromInitialAndOlderPagesAfterRestoration() throws {
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(2), diagnosticRow(3, unknown: true), diagnosticRow(4)])])
    let older = diagnosticWindow([diagnosticView([diagnosticRow(0, unknown: true), diagnosticRow(1), diagnosticRow(2)])])
    var current = initial
    var scrolls = 0
    let driver = SlackHistory.Driver(snapshot: { current }, scrollToVisible: { _ in
        scrolls += 1
        current = scrolls == 1 ? older : initial
        return true
    }, pause: {})
    let command = try Slack.parse(["--history", "1"])
    var warnings: [String] = []
    let output = try command.read(using: driver, warn: { warnings.append($0) })
    #expect(output.contains("unknown body 0"))
    #expect(output.contains("unknown body 3"))
    #expect(output.contains("known body 1"))
    #expect(output.contains("known body 4"))
    #expect(warnings.count == 1)
    #expect(scrolls == 3)
}

@Test func retainsCandidatesWhenAnObservedPageHasNoRecognisableRows() throws {
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(1), diagnosticRow(2)])])
    let older = diagnosticWindow([diagnosticView([diagnosticRow(0, unknown: true)])])
    var current = initial
    var scrolls = 0
    let driver = SlackHistory.Driver(snapshot: { current }, scrollToVisible: { _ in
        scrolls += 1
        current = scrolls == 1 ? older : initial
        return true
    }, pause: {})
    var warnings: [String] = []
    let output = try Slack.parse(["--history", "1"]).read(using: driver, warn: { warnings.append($0) })
    #expect(output.contains("unknown body 0"))
    #expect(output.contains("known body 2"))
    #expect(warnings.count == 1)
}

@Test func keepsInterpretedAndUnknownVersionsWhenRestoringFails() throws {
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(1), diagnosticRow(2)])])
    let older = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1, unknown: true)])])
    var current = initial
    var scrolls = 0
    let driver = SlackHistory.Driver(snapshot: { current }, scrollToVisible: { _ in
        scrolls += 1
        current = older
        return scrolls == 1
    }, pause: {})
    var warnings: [String] = []
    let output = try Slack.parse(["--history", "1", "--find", "known body 1", "--context", "0"])
        .read(using: driver, warn: { warnings.append($0) })
    #expect(output.contains("known body 1"))
    #expect(output.contains("unknown body 1"))
    #expect(!output.contains("body 0"))
    #expect(warnings.count == 1)
}

@Test(arguments: [false, true])
func preservesReadFailuresBeforeAndDuringCollection(duringCollection: Bool) throws {
    enum ReadError: Error { case failed }
    let windows = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1, unknown: true)])])
    var reads = 0
    var warnings: [String] = []
    let driver = SlackHistory.Driver(snapshot: {
        reads += 1
        if !duringCollection || reads > 1 { throw ReadError.failed }
        return windows
    }, scrollToVisible: { _ in true }, pause: {})
    #expect(throws: ReadError.self) {
        try Slack.parse(["--history", "1"]).read(using: driver, warn: { warnings.append($0) })
    }
    #expect(warnings.isEmpty)
}

@Test func doesNotWarnForEmptyKnownViewsOrOmittedFieldsAndSeparators() throws {
    let divider = Node(role: "AXGroup", domID: "message-list_1700000000000.C123", domClasses: ["c-virtual_list__item"])
    let composer = Node(role: "AXTextArea", value: "draft", domID: "message-list_Thread_input")
    let sidebar = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
                       children: [Node(role: "AXStaticText", value: "Home")])
    let emptySearch = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
                           children: [Node(role: "AXGroup", domClasses: ["resultCounts__example"],
                                           children: [Node(role: "AXStaticText", value: "0 results")])])
    var search = diagnosticRow(3)
    search.domID = "search-result"
    search.domClasses = []
    let searchView = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"], children: [search])
    for views in [
        [diagnosticView([]), diagnosticView([], thread: true), emptySearch, sidebar],
        [diagnosticView([divider, composer, diagnosticRow(0), diagnosticRow(1)]), searchView, sidebar],
        [diagnosticView([diagnosticRow(2, prefix: "message-list_Thread_")], thread: true)]
    ] {
        #expect(try diagnosticRead(diagnosticWindow(views)).1.isEmpty)
    }
}

@Test func anUnknownOtherPaneDoesNotWarnForTheSelectedThread() throws {
    var unknown = diagnosticView([diagnosticRow(0, unknown: true)])
    unknown.domClasses = ["p-view_contents"]
    unknown.children = [Node(role: "AXStaticText", value: "unknown conversation")]
    let windows = diagnosticWindow([unknown, diagnosticView([diagnosticRow(2, prefix: "message-list_Thread_")], thread: true)])
    let (output, warnings) = try diagnosticRead(windows, arguments: ["--thread"])
    #expect(output.contains("known body 2"))
    #expect(!output.contains("unknown conversation"))
    #expect(warnings.isEmpty)
}

private final class DiagnosticTestBundle: NSObject {}

private func diagnosticCLI(_ windows: [Node], arguments: [String] = []) throws -> (String, String, Int32) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = directory.appendingPathComponent("screen.json")
    try JSONEncoder().encode(windows).write(to: snapshot)
    let process = Process()
    let products = Bundle(for: DiagnosticTestBundle.self).bundleURL.deletingLastPathComponent()
    process.executableURL = products.appendingPathComponent("romsen")
    process.arguments = ["slack", "--from-snapshot", snapshot.path] + arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), process.terminationStatus)
}

@Test func reportsWarningsAndPreservesExitStatusAtTheCLIBoundary() throws {
    let normal = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(2)])])
    let mixed = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1, unknown: true), diagnosticRow(2)])])
    let unknown = diagnosticWindow([Node(role: "AXGroup", children: [Node(role: "AXStaticText", value: "unidentified text")])])
    let normalResult = try diagnosticCLI(normal)
    #expect(normalResult.0.contains("known body 0"))
    #expect(normalResult.1.isEmpty)
    #expect(normalResult.2 == 0)
    for args in [[], ["--last", "2"], ["--find", "known body 2", "--context", "1"],
                 ["https://example.slack.com/archives/C123/p1700000002000100", "--context", "1"]] {
        let result = try diagnosticCLI(mixed, arguments: args)
        #expect(result.0.contains("unknown body 1"))
        #expect(result.1.contains("warning:"))
        #expect(!result.1.contains("body"))
        #expect(result.1.split(separator: "\n").count == 1)
        #expect(result.2 == 0)
    }
    let fallback = try diagnosticCLI(unknown)
    #expect(fallback.0.contains("unidentified text"))
    #expect(fallback.1.contains("warning:"))
    #expect(fallback.2 == 0)
    let limited = try diagnosticCLI(unknown, arguments: ["--last", "1"])
    #expect(!limited.0.contains("unidentified text"))
    #expect(limited.1.contains("Unidentified text was omitted"))
    #expect(limited.2 == 0)
    let raw = try diagnosticCLI(mixed, arguments: ["--raw"])
    #expect(raw.0.contains("changed-message"))
    #expect(raw.1.isEmpty)
    #expect(raw.2 == 0)
    for args in [["--thread"], ["--find", "missing"], ["https://example.slack.com/archives/C123/p1700000009000100"]] {
        let result = try diagnosticCLI(unknown, arguments: args)
        #expect(result.0.isEmpty)
        #expect(!result.1.contains("warning:"))
        #expect(result.2 != 0)
    }
    var mismatch = mixed
    mismatch[0].children[0].children[0].children.insert(
        Node(role: "AXGroup", domID: "message-list_1700000000000.C999"), at: 0)
    let rejected = try diagnosticCLI(mismatch, arguments: ["https://example.slack.com/archives/C123/p1700000000000100"])
    #expect(rejected.0.isEmpty)
    #expect(rejected.1.contains("but Slack is showing C999"))
    #expect(!rejected.1.contains("warning:"))
    #expect(rejected.2 != 0)
    for args in [["--find", "unknown body 1"], ["https://example.slack.com/archives/C123/p1700000001000100"]] {
        let result = try diagnosticCLI(mixed, arguments: args)
        #expect(result.0.isEmpty)
        #expect(!result.1.contains("warning:"))
        #expect(result.2 != 0)
    }
}

@Test func detectsMissingContentViewsBesideTheNormalSidebar() throws {
    let sidebar = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
                       children: [Node(role: "AXStaticText", value: "sidebar text")])
    var missing = diagnosticView([diagnosticRow(0), diagnosticRow(1, unknown: true)])
    missing.domClasses = ["changed-view"]
    for other in [[sidebar], [sidebar, diagnosticView([diagnosticRow(2, prefix: "message-list_Thread_")], thread: true)]] {
        let windows = diagnosticWindow(other + [missing])
        let all = try diagnosticCLI(windows)
        #expect(all.0.contains("known body 0"))
        #expect(all.0.contains("unknown body 1"))
        #expect(!all.0.contains("sidebar text"))
        #expect(all.1.contains("warning:"))
        #expect(all.2 == 0)
        let limited = try diagnosticCLI(windows, arguments: ["--last", "1"])
        #expect(!limited.0.contains("body"))
        #expect(limited.1.contains("Unidentified text was omitted"))
        #expect(limited.2 == 0)
    }
    let workspace = Node(role: "AXGroup", description: "Example workspace", domClasses: ["p-client_workspace_wrapper"],
                         children: [sidebar])
    let sidebarAlone = try diagnosticRead(diagnosticWindow([workspace]))
    #expect(!sidebarAlone.0.contains("sidebar text"))
    #expect(sidebarAlone.1.isEmpty)
}

@Test(arguments: [false, true])
func keepsUnknownRowsNestedUnderWrappers(wrapKnownRows: Bool) throws {
    let wrapper = Node(role: "AXGroup", children: [diagnosticRow(1, unknown: true)])
    let first = wrapKnownRows ? Node(role: "AXGroup", children: [diagnosticRow(0)]) : diagnosticRow(0)
    let last = wrapKnownRows ? Node(role: "AXGroup", children: [diagnosticRow(2)]) : diagnosticRow(2)
    let windows = diagnosticWindow([diagnosticView([first, wrapper, last])])
    let result = try diagnosticCLI(windows)
    #expect(result.0.contains("known body 0"))
    #expect(result.0.contains("unknown body 1"))
    #expect(result.0.contains("known body 2"))
    #expect(result.1.contains("warning:"))
    #expect(result.2 == 0)
}

@Test(arguments: [false, true])
func keepsRecognisedRowsAcrossUnknownVersionsAndClipping(nested: Bool) throws {
    var unknown = diagnosticRow(1, unknown: true)
    unknown.frame = CGRect(x: 0, y: 0, width: 100, height: 20)
    var known = diagnosticRow(1)
    known.frame = CGRect(x: 0, y: 0, width: 100, height: 1)
    if nested { known.children = [Node(role: "AXGroup", children: known.children)] }
    for unknownFirst in [false, true] {
        let initial = diagnosticWindow([diagnosticView([unknownFirst ? unknown : known, diagnosticRow(2)])])
        let older = diagnosticWindow([diagnosticView([diagnosticRow(0), unknownFirst ? known : unknown])])
        var current = initial
        var scrolls = 0
        let driver = SlackHistory.Driver(snapshot: { current }, scrollToVisible: { _ in
            scrolls += 1
            current = older
            return scrolls == 1
        }, pause: {})
        var warnings: [String] = []
        let output = try Slack.parse(["--history", "1", "--find", "known body 1", "--context", "0"])
            .read(using: driver, warn: { warnings.append($0) })
        #expect(output.contains("known body 1"))
        #expect(output.contains("unknown body 1"))
        #expect(warnings.count == 1)
    }
}

@Test func continuesSearchingPastAnUnknownMatchingRow() throws {
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(3, unknown: true), diagnosticRow(4)])])
    let older = diagnosticWindow([diagnosticView([diagnosticRow(1), diagnosticRow(2), diagnosticRow(3)])])
    var current = initial
    var scrolls = 0
    let driver = SlackHistory.Driver(snapshot: { current }, scrollToVisible: { _ in
        scrolls += 1
        current = older
        return scrolls == 1
    }, pause: {})
    var warnings: [String] = []
    let output = try Slack.parse(["--find", "body 3", "--context", "0"])
        .read(using: driver, warn: { warnings.append($0) })
    #expect(scrolls > 0)
    #expect(output.contains("known body 3"))
    #expect(output.contains("unknown body 3"))
    #expect(warnings.count == 1)
}

@Test(arguments: ["AXList", "AXGroup"])
func limitsAListOfWrappedUnknownRows(listRole: String) throws {
    let wrappers = (0..<3).map { Node(role: "AXGroup", children: [diagnosticRow($0, unknown: true)]) }
    var view = diagnosticView(wrappers)
    view.children[0].role = listRole
    let result = try diagnosticCLI(diagnosticWindow([view]), arguments: ["--last", "1"])
    #expect(!result.0.contains("body 0"))
    #expect(!result.0.contains("body 1"))
    #expect(result.0.contains("unknown body 2"))
    #expect(result.1.contains("warning:"))
    #expect(result.2 == 0)
}

@Test func doesNotTreatEmptySearchResultsAndToolbarTextAsBrokenContent() throws {
    let search = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"],
                      children: [Node(role: "AXGroup", domClasses: ["resultCounts__example"],
                                      children: [Node(role: "AXStaticText", value: "0 results")])])
    let windows = diagnosticWindow([Node(role: "AXButton", title: "Search"), search])
    let result = try diagnosticCLI(windows)
    #expect(!result.0.contains("untitled view"))
    #expect(result.1.isEmpty)
    #expect(result.2 == 0)
}

@Test func preservesSearchResultsAndTheirSummaryWhenTheyIncludeUnknownRows() throws {
    var known = diagnosticRow(0)
    known.domID = "search-result"
    known.domClasses = []
    let search = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"], children: [
        Node(role: "AXGroup", domClasses: ["headerContainer__example"], children: [Node(role: "AXStaticText", value: "search query")]),
        known, diagnosticRow(1, unknown: true)
    ])
    let result = try diagnosticCLI(diagnosticWindow([search]))
    #expect(result.0.contains("search query"))
    #expect(result.0.contains("known body 0"))
    #expect(result.0.contains("unknown body 1"))
    #expect(result.1.contains("warning:"))
    #expect(result.2 == 0)
}

@Test func doesNotSubstituteAThreadForAnUnrecognisedConversation() throws {
    let windows = diagnosticWindow([
        diagnosticView([diagnosticRow(0, unknown: true), diagnosticRow(1, unknown: true)]),
        diagnosticView([diagnosticRow(2, prefix: "message-list_Thread_")], thread: true)
    ])
    let result = try diagnosticCLI(windows, arguments: ["--last", "1"])
    #expect(!result.0.contains("body 0"))
    #expect(result.0.contains("unknown body 1"))
    #expect(!result.0.contains("body 2"))
    #expect(result.1.contains("warning:"))
    #expect(result.2 == 0)
}

@Test func warnsWhenAFocusTargetLosesItsViewIdentity() throws {
    var missing = diagnosticView([diagnosticRow(0), diagnosticRow(1)])
    missing.domClasses = ["changed-view"]
    let windows = diagnosticWindow([missing])
    let link = "https://example.slack.com/archives/C123/p1700000000000100"
    for args in [["--find", "known body 0", "--context", "0"], [link, "--context", "0"]] {
        let result = try diagnosticCLI(windows, arguments: args)
        #expect(!result.0.contains("body"))
        #expect(result.1.contains("Unidentified text was omitted"))
        #expect(result.2 == 0)
        let live = try diagnosticRead(windows, arguments: args)
        #expect(!live.0.contains("body"))
        #expect(live.1.count == 1)
    }
    let otherPane = diagnosticView([diagnosticRow(2, prefix: "message-list_Thread_")], thread: true)
    let unrelated = try diagnosticRead(diagnosticWindow([missing, otherPane]),
                                      arguments: ["--thread", "--find", "known body 2", "--context", "0"])
    #expect(unrelated.0.contains("body 2"))
    #expect(!unrelated.0.contains("body 0"))
    #expect(unrelated.1.isEmpty)
}

@Test func doesNotWarnAboutAnUnselectedCopyOfTheLinkedThreadRoot() throws {
    var missing = diagnosticView([diagnosticRow(0)])
    missing.domClasses = ["changed-view"]
    let thread = diagnosticView([
        diagnosticRow(0, prefix: "message-list_Thread_"),
        Node(role: "AXGroup", domID: "message-list_Thread_separator"),
        diagnosticRow(1, prefix: "message-list_Thread_")
    ], thread: true)
    let result = try diagnosticCLI(diagnosticWindow([missing, thread]),
        arguments: ["https://example.slack.com/archives/C123/p1700000000000100", "--thread"])
    #expect(result.0.contains("known body 0"))
    #expect(result.0.contains("known body 1"))
    #expect(result.1.isEmpty)
    #expect(result.2 == 0)
}

@Test func doesNotSubstituteAnotherPaneForAnUnidentifiedLinkedPane() throws {
    var missing = diagnosticView([diagnosticRow(0), diagnosticRow(1)])
    missing.domClasses = ["changed-view"]
    let thread = diagnosticView([
        diagnosticRow(0, prefix: "message-list_Thread_"),
        Node(role: "AXGroup", domID: "message-list_Thread_separator"),
        diagnosticRow(2, prefix: "message-list_Thread_")
    ], thread: true)
    let windows = diagnosticWindow([missing, thread])
    let arguments = ["https://example.slack.com/archives/C123/p1700000000000100", "--context", "1"]
    let live = try diagnosticRead(windows, arguments: arguments)
    let saved = try diagnosticCLI(windows, arguments: arguments)
    #expect(!live.0.contains("body"))
    #expect(saved.0 == live.0 + "\n")
    #expect(live.1 == [SlackInterpreter.Diagnostic.unidentifiedPane.rawValue])
    #expect(saved.1 == "romsen: warning: \(SlackInterpreter.Diagnostic.unidentifiedPane.rawValue)\n")
    #expect(saved.2 == 0)

    var changedThread = thread
    changedThread.domClasses = ["changed-view"]
    let threadMissing = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1)]), changedThread])
    let reply = ["https://example.slack.com/archives/C123/p1700000002000100?thread_ts=1700000000.000100"]
    #expect(throws: SlackRead.Failure.self) { try diagnosticRead(threadMissing, arguments: reply) }
    let failed = try diagnosticCLI(threadMissing, arguments: reply)
    #expect(failed.0.isEmpty)
    #expect(!failed.1.contains("warning:"))
    #expect(failed.2 != 0)
}

@Test func readsLinksOnRecognisedScreensTheSameLiveAndSaved() throws {
    func thread(separator: String) -> Node {
        diagnosticView([
            diagnosticRow(0, prefix: "message-list_Thread_"), Node(role: "AXGroup", domID: separator),
            diagnosticRow(2, prefix: "message-list_Thread_"), diagnosticRow(3, prefix: "message-list_Thread_")
        ], thread: true)
    }
    let conversation = diagnosticWindow([diagnosticView([diagnosticRow(0), diagnosticRow(1)]),
                                         thread(separator: "message-list_Thread_separator")])
    var result = diagnosticRow(4)
    result.domID = "search-result"
    result.domClasses = []
    let search = Node(role: "AXGroup", domClasses: ["p-view_contents", "p-view_contents--sidebar"], children: [result])
    // Without a conversation list the thread list is checked for a channel, so its separator must not look like one.
    let beside = diagnosticWindow([search, thread(separator: "message-list_Thread_1700000000.000100_separator")])
    let link = "https://example.slack.com/archives/C123/p"
    let reply = link + "1700000002000100?thread_ts=1700000000.000100"
    let cases: [([Node], [String], [String], [String])] = [
        (conversation, [link + "1700000001000100", "--context", "1"], ["known body 0", "known body 1"], ["body 2"]),
        (conversation, [link + "1700000000000100", "--context", "0"], ["known body 0"], ["body 1", "body 2"]),
        (conversation, [reply, "--context", "0"], ["known body 2"], ["body 0", "body 3"]),
        (conversation, [link + "1700000000000100", "--thread"], ["known body 0", "known body 2", "known body 3"], ["body 1"]),
        (beside, [reply, "--context", "1"], ["known body 0", "known body 2", "known body 3"], ["body 4"]),
        (beside, [link + "1700000000000100", "--thread"], ["known body 0", "known body 2", "known body 3"], ["body 4"])
    ]
    for (windows, arguments, present, absent) in cases {
        let live = try diagnosticRead(windows, arguments: arguments)
        let saved = try diagnosticCLI(windows, arguments: arguments)
        #expect(saved.0 == live.0 + "\n")
        #expect(live.1.isEmpty)
        #expect(saved.1.isEmpty)
        #expect(saved.2 == 0)
        for text in present { #expect(live.0.contains(text)) }
        for text in absent { #expect(!live.0.contains(text)) }
        #expect(live.0.components(separatedBy: "\n## ").count == 2)
    }
}

@Test func limitsTheOutputEvenWhenMissingRowIDsPreventCollection() throws {
    var missingID = diagnosticRow(0)
    missingID.domID = nil
    let windows = diagnosticWindow([diagnosticView([missingID, diagnosticRow(1, unknown: true), diagnosticRow(2)])])
    let result = try diagnosticCLI(windows, arguments: ["--last", "1"])
    #expect(!result.0.contains("body 0"))
    #expect(!result.0.contains("body 1"))
    #expect(result.0.contains("known body 2"))
    #expect(result.1.isEmpty)
    #expect(result.2 == 0)
}

@Test(arguments: [false, true])
func preservesRecognisableContentWhenPagingClassesDisappear(nested: Bool) throws {
    var known = diagnosticRow(0)
    var unknown = diagnosticRow(1, unknown: true)
    known.domClasses = []
    unknown.domClasses = []
    if nested { known.children = [Node(role: "AXGroup", children: known.children)] }
    let result = try diagnosticCLI(diagnosticWindow([diagnosticView([known, unknown])]))
    #expect(result.0.contains("known body 0"))
    #expect(result.0.contains("unknown body 1"))
    #expect(result.1.contains("warning:"))
    #expect(result.2 == 0)
}

@Test func preservesTheInitialUnknownRepliesOfAnAlreadyOpenLinkedThread() throws {
    let root = diagnosticRow(0, prefix: "message-list_Thread_")
    let separator = Node(role: "AXGroup", domID: "message-list_Thread_separator")
    let initial = diagnosticWindow([
        diagnosticView([diagnosticRow(0)]),
        diagnosticView([root, separator, diagnosticRow(1, unknown: true, prefix: "message-list_Thread_")], thread: true)
    ])
    let later = diagnosticWindow([
        diagnosticView([diagnosticRow(0)]),
        diagnosticView([root, separator, diagnosticRow(1, prefix: "message-list_Thread_")], thread: true)
    ])
    var reads = 0
    let driver = SlackHistory.Driver(snapshot: {
        reads += 1
        return reads == 1 ? initial : later
    }, scrollToVisible: { _ in false }, pause: {})
    let arguments = ["https://example.slack.com/archives/C123/p1700000000000100", "--thread"]
    var warnings: [String] = []
    let output = try Slack.parse(arguments).read(using: driver, warn: { warnings.append($0) })
    #expect(output.contains("unknown body 1"))
    #expect(warnings.count == 1)
    let replay = try diagnosticCLI(initial, arguments: arguments)
    #expect(replay.0.contains("unknown body 1"))
    #expect(replay.1.contains(try #require(warnings.first)))
    #expect(replay.2 == 0)
}

@Test(arguments: [false, true])
func preservesUnknownRepliesSeenWhileConfirmingANewlyOpenedThread(missingLastID: Bool) throws {
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(0)])])
    let opened = diagnosticWindow([
        diagnosticView([diagnosticRow(0)]),
        diagnosticView([
            diagnosticRow(0, prefix: "message-list_Thread_"),
            Node(role: "AXGroup", domID: "message-list_Thread_separator"),
            diagnosticRow(1, unknown: true, prefix: "message-list_Thread_")
        ], thread: true)
    ])
    var later = opened
    later[0].children[1].children[0].children.removeLast()
    if missingLastID {
        var last = diagnosticRow(2, prefix: "message-list_Thread_")
        last.domID = nil
        later[0].children[1].children[0].children.append(last)
    }
    var pressed = false
    var threadReads = 0
    let driver = SlackHistory.Driver(snapshot: {
        guard pressed else { return initial }
        threadReads += 1
        return threadReads == 1 ? opened : later
    }, scrollToVisible: { _ in false }, pause: {}, press: { _, _ in
        pressed = true
        return true
    })
    var warnings: [String] = []
    let output = try Slack.parse(["https://example.slack.com/archives/C123/p1700000000000100", "--thread"])
        .read(using: driver, warn: { warnings.append($0) })
    if missingLastID {
        var request = SlackHistory.Request()
        request.pane = .thread
        let retained = try SlackHistory.collect(request, driver: driver, initial: later, observations: [opened])
        let result = try diagnosticRead(retained, arguments: ["--thread"])
        #expect(result.0.contains("unknown body 1"))
        #expect(result.0.contains("known body 2"))
        #expect(result.1.count == 1)
    }
    #expect(pressed)
    #expect(threadReads > 1)
    #expect(output.contains("unknown body 1"))
    #expect(warnings.count == 1)
}

@Test func retainsTextFromEveryObservationOfAnUnknownRow() throws {
    var row = diagnosticRow(1, unknown: true)
    let initial = diagnosticWindow([diagnosticView([diagnosticRow(0), row, diagnosticRow(2)])])
    row.children = [Node(role: "AXStaticText", value: "later acquired text")]
    let later = diagnosticWindow([diagnosticView([diagnosticRow(0), row, diagnosticRow(2)])])
    var reads = 0
    let driver = SlackHistory.Driver(snapshot: {
        reads += 1
        return reads == 1 ? initial : later
    }, scrollToVisible: { _ in true }, pause: {})
    var warnings: [String] = []
    let output = try Slack.parse(["--history", "1"]).read(using: driver, warn: { warnings.append($0) })
    #expect(output.contains("unknown body 1"))
    #expect(output.contains("later acquired text"))
    #expect(output.components(separatedBy: "later acquired text").count == 2)
    #expect(warnings.count == 1)
}
