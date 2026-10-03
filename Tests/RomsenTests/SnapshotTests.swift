import AXTree
import Foundation
import SlackAdapter
import Testing

@testable import romsen

private func row(_ timestamp: String, _ text: String, prefix: String = "message-list_") -> Node {
    Node(role: "AXGroup", domID: prefix + timestamp, domClasses: ["c-virtual_list__item"],
         children: [Node(role: "AXGroup", domClasses: ["c-message_kit__hover"], children: [
            Node(role: "AXGroup", domClasses: ["p-rich_text_section"],
                 children: [Node(role: "AXStaticText", value: text)])
         ])])
}

private func screen(threadRoot: String? = nil) -> [Node] {
    var views = [Node(role: "AXGroup", description: "Channel example", domClasses: ["p-view_contents"],
                      children: [Node(role: "AXList", children: [
                        row("1700000000.000100", "first"), row("1700000001.000100", "needle last")
                      ])])]
    if let threadRoot {
        views.append(Node(role: "AXGroup", description: "Thread", domClasses: ["p-view_contents", "p-view_contents--secondary"],
                          children: [Node(role: "AXList", children: [
                            row(threadRoot, "root", prefix: "message-list_Thread_"),
                            Node(role: "AXGroup", domID: "message-list_Thread_separator"),
                            row("1700000002.000100", "reply", prefix: "message-list_Thread_")
                          ])]))
    }
    return [Node(role: "AXWindow", children: views)]
}

private func withSnapshot(_ windows: [Node], _ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    try JSONEncoder().encode(windows).write(to: url)
    try body(url)
}

@Test func preservesEveryCapturedAttributeThroughAFileRoundTrip() throws {
    let windows = [Node(role: "AXWindow", subrole: "AXStandardWindow", title: "Synthetic window",
                        value: "", description: "日本語\n\"quoted\"", domID: "example", domClasses: ["one", "two"],
                        frame: CGRect(x: -12.5, y: 8.25, width: 640.5, height: 1), children: [
                            Node(role: "AXGroup", children: [Node(role: "AXStaticText", value: "child")]),
                            Node(role: "AXUnknown")
                        ]), Node(role: "AXWindow")]
    try withSnapshot(windows) { url in
        let restored = try JSONDecoder().decode([Node].self, from: Data(contentsOf: url))
        #expect(restored == windows)
    }
}

@Test func savesTheInitialReadAndReplaysTheSameOutput() throws {
    let windows = screen()
    try withSnapshot([]) { url in
        var command = try Slack.parse([])
        command.saveSnapshot = url.path
        var snapshots = 0
        let driver = SlackHistory.Driver(snapshot: {
            snapshots += 1
            return snapshots == 1 ? windows : screen(threadRoot: "1700000000.000100")
        }, scrollToVisible: { _ in
            Issue.record("A default read must not scroll")
            return false
        }, pause: { Issue.record("A default read must not wait") }, press: { _, _ in
            Issue.record("A default read must not click")
            return false
        })
        let output = try command.read(using: driver)
        #expect(output.contains("first"))
        #expect(!output.contains("reply"))
        let restored = try JSONDecoder().decode([Node].self, from: Data(contentsOf: url))
        #expect(restored == windows)
        command.saveSnapshot = nil
        command.fromSnapshot = url.path
        #expect(try command.read(using: command.makeDriver()) == output)
        command.raw = true
        #expect(try command.read(using: command.makeDriver()) == windows.map { $0.outline() }.joined(separator: "\n"))
    }
}

@Test(arguments: [false, true])
func savesBeforeScrollingOrOpeningAThread(openThread: Bool) throws {
    let original = screen()
    try withSnapshot([]) { url in
        var command = try Slack.parse([])
        command.saveSnapshot = url.path
        command.history = openThread ? 0 : 1
        command.thread = openThread
        command.link = openThread ? "https://example.slack.com/archives/C123/p1700000000000100" : nil
        var current = original
        var actions = 0
        func checkSavedBeforeActing() {
            let data = try? Data(contentsOf: url)
            let saved = data.flatMap { try? JSONDecoder().decode([Node].self, from: $0) }
            #expect(saved == original)
        }
        let driver = SlackHistory.Driver(snapshot: { current }, scrollToVisible: { _ in
            checkSavedBeforeActing()
            actions += 1
            current[0].title = "After scrolling"
            return false
        }, pause: {}, press: { _, _ in
            checkSavedBeforeActing()
            actions += 1
            current = screen(threadRoot: "1700000000.000100")
            return true
        })
        _ = try command.read(using: driver)
        #expect(actions > 0)
        #expect(current != original)
        let restored = try JSONDecoder().decode([Node].self, from: Data(contentsOf: url))
        #expect(restored == original)
    }
}

@Test func replayStopsAtTheSavedRangeAndCannotNavigate() throws {
    try withSnapshot(screen()) { url in
        var command = try Slack.parse([])
        command.fromSnapshot = url.path
        let driver = try command.makeDriver()
        #expect(!driver.scrollToVisible("message-list_1700000000.000100"))
        #expect(!driver.press("message-list_1700000000.000100", "c-message__reply_count"))
        driver.pause()
        command.last = 100
        command.history = 100
        let output = try command.read(using: driver)
        #expect(output.contains("first"))
        #expect(output.contains("needle last"))
        command.last = 1
        #expect(try !command.read(using: driver).contains("first"))
        command.last = nil
        command.find = "absent"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
        command.find = "needle"
        command.context = 0
        #expect(try command.read(using: driver).contains("needle last"))
        command.find = nil
        command.link = "https://example.slack.com/archives/C123/p1700000000000100"
        #expect(try command.read(using: driver).contains("first"))
        command.thread = true
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
    }
}

@Test func replayReadsOnlyAnAlreadyOpenLinkedThread() throws {
    try withSnapshot(screen(threadRoot: "1700000000.000100")) { url in
        var command = try Slack.parse([])
        command.fromSnapshot = url.path
        command.thread = true
        let driver = try command.makeDriver()
        #expect(try command.read(using: driver).contains("reply"))
        command.link = "https://example.slack.com/archives/C123/p1700000000000100"
        let linked = try command.read(using: driver)
        #expect(linked.contains("reply"))
        #expect(!linked.contains("first"))
        command.link = "https://example.slack.com/archives/C123/p1700000001000100?thread_ts=1700000000.000100"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
        command.link = "https://example.slack.com/archives/C123/p1700000001000100"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
        command.link = "https://example.slack.com/archives/C123/p1700000002000100"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
        command.link = "https://example.slack.com/archives/C123/p1700000002000100?thread_ts=1700000002.000100"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
        command.link = "https://example.slack.com/archives/C123/p1700000002000100?thread_ts=1700000000.000100"
        #expect(try command.read(using: driver).contains("reply"))
        command.thread = false
        command.link = "https://example.slack.com/archives/C123/p1700000000000100"
        let conversation = try command.read(using: driver)
        #expect(conversation.contains("first"))
        #expect(!conversation.contains("root"))
        command.link = "https://example.slack.com/archives/C123/p1700000002000100"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
    }
}

@Test func replayCannotIdentifyAThreadWithItsStartOutsideTheSavedRange() throws {
    var windows = screen(threadRoot: "1700000000.000100")
    windows[0].children[1].children[0].children.removeFirst(2)
    try withSnapshot(windows) { url in
        var command = try Slack.parse([])
        command.fromSnapshot = url.path
        command.thread = true
        let driver = try command.makeDriver()
        #expect(try command.read(using: driver).contains("reply"))
        command.link = "https://example.slack.com/archives/C123/p1700000002000100"
        #expect(throws: SlackRead.Failure.self) { try command.read(using: driver) }
    }
}

@Test func reportsUnreadableAndMalformedSnapshotFiles() throws {
    var command = try Slack.parse([])
    command.fromSnapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    #expect(throws: (any Error).self) { try command.makeDriver() }
    try withSnapshot([]) { url in
        try Data("invalid json".utf8).write(to: url)
        command.fromSnapshot = url.path
        #expect(throws: (any Error).self) { try command.makeDriver() }
    }
}
