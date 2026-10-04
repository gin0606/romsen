import ApplicationServices
import AXTree
import Foundation
import Testing

@testable import AXSnapshot

private func errorValue(_ error: AXError) -> AXValue {
    var error = error
    return AXValueCreate(.axError, &error)!
}

@Test func distinguishesMissingOptionalAttributesFromAcquisitionFailures() throws {
    let values = try AXAccess.attributeResults(.success,
        values: ["AXButton", errorValue(.attributeUnsupported), errorValue(.noValue)],
        names: ["AXRole", "AXTitle", "AXValue"])
    #expect(values[0] as? String == "AXButton")
    #expect(values[1] == nil && values[2] == nil)
    #expect(throws: ReaderError.acquisitionFailed(operation: "read attributes", code: AXError.cannotComplete.rawValue)) {
        try AXAccess.attributeResults(.cannotComplete, values: nil, names: ["AXRole"])
    }
    #expect(throws: ReaderError.acquisitionFailed(operation: "AXChildren", code: AXError.cannotComplete.rawValue)) {
        try AXAccess.attributeResults(.success, values: [errorValue(.cannotComplete)], names: ["AXChildren"])
    }
    #expect(throws: ReaderError.invalidAttribute("attribute results")) {
        try AXAccess.attributeResults(.success, values: [], names: ["AXRole"])
    }
}

@Test func distinguishesMissingWindowsFromFailedWindowQueries() throws {
    #expect(try AXAccess.attributeResult(.noValue, value: nil, name: "AXFocusedWindow") == nil)
    for error in [AXError.cannotComplete, .attributeUnsupported, .apiDisabled] {
        #expect(throws: ReaderError.acquisitionFailed(operation: "AXFocusedWindow", code: error.rawValue)) {
            try AXAccess.attributeResult(error, value: nil, name: "AXFocusedWindow")
        }
    }
    #expect(throws: ReaderError.invalidAttribute("AXWindows")) {
        try AXAccess.attributeResult(.success, value: nil, name: "AXWindows")
    }
    #expect(!ReaderError.noFocusedWindow(bundleID: "example.app").description.contains("browser"))
}

private func capture(_ tree: [Int: [String: Any]], web: Bool = false, limit: Int = 50_000,
                     depth: Int = 512, supported: [String] = []) -> SnapshotCapture<Int> {
    SnapshotCapture(includeWebSemantics: web, remainingNodes: limit, depthLimit: depth,
        values: { id, names in names.map { tree[id]?[$0] } }, names: { _ in supported })
}

@Test func capturesOptionalWebStateAndGeometryWithoutRequiringItForOrdinaryReads() throws {
    var frame = CGRect(x: 5, y: 10, width: 90, height: 30)
    var range = CFRange(location: 2, length: 3)
    let tree: [Int: [String: Any]] = [0: ["AXRole": "AXWindow", "AXChildren": [1]], 1: [
        "AXRole": "AXCheckBox", "AXValue": NSNumber(value: 1), "AXEnabled": false,
        "AXExpanded": false, "AXURL": URL(string: "https://example.com/")!,
        "AXRowIndexRange": AXValueCreate(.cfRange, &range)!, "AXFrame": AXValueCreate(.cgRect, &frame)!
    ]]
    var ordinary = capture(tree)
    let base = try ordinary.windows([0])[0].children[0]
    #expect(base.frame == frame)
    #expect(base.web == nil)
    var rich = capture(tree, web: true)
    let node = try rich.windows([0])[0].children[0]
    #expect(node.value == "1")
    #expect(node.web?.enabled == false)
    #expect(node.web?.expanded == nil)
    #expect(node.web?.rowIndex == 2 && node.web?.rowSpan == 3)
    #expect(node.web?.url == "https://example.com/")
    var expandable = capture(tree, web: true, supported: ["AXExpanded"])
    #expect(try expandable.windows([0])[0].children[0].web?.expanded == false)
}

@Test func neverReturnsATruncatedTreeOrFabricatesAMissingRole() throws {
    let tree: [Int: [String: Any]] = [0: ["AXRole": "AXWindow", "AXChildren": [1]], 1: ["AXRole": "AXStaticText", "AXValue": "body"]]
    var exact = capture(tree, limit: 2)
    #expect(try exact.windows([0])[0].children[0].value == "body")
    var limited = capture(tree, limit: 1)
    #expect(throws: ReaderError.nodeLimitExceeded) { try limited.windows([0]) }
    var multipleWindows = capture(tree, limit: 2)
    #expect(throws: ReaderError.nodeLimitExceeded) { try multipleWindows.windows([0, 0]) }
    var deep = capture(tree, depth: 1)
    #expect(throws: ReaderError.depthLimitExceeded) { try deep.windows([0]) }
    var noRole = capture([0: ["AXTitle": "unknown"]])
    #expect(throws: ReaderError.invalidAttribute("AXRole")) { try noRole.windows([0]) }
    var badChildren = capture([0: ["AXRole": "AXWindow", "AXChildren": "invalid"]])
    #expect(throws: ReaderError.invalidAttribute("AXChildren")) { try badChildren.windows([0]) }
}

@Test func headerReferencesShareTheTraversalBudget() throws {
    let tree: [Int: [String: Any]] = [0: ["AXRole": "AXTable", "AXColumnHeaderUIElements": [1]],
                                     1: ["AXRole": "AXGroup", "AXChildren": [2]],
                                     2: ["AXRole": "AXStaticText", "AXValue": "Price"]]
    var complete = capture(tree, web: true, limit: 3)
    #expect(try complete.windows([0])[0].web?.columnHeaders == ["Price"])
    var limited = capture(tree, web: true, limit: 2)
    #expect(throws: ReaderError.nodeLimitExceeded) { try limited.windows([0]) }
    var cycle = capture([0: ["AXRole": "AXTable", "AXColumnHeaderUIElements": [1]],
                         1: ["AXChildren": [1]]], web: true, depth: 4)
    #expect(throws: ReaderError.depthLimitExceeded) { try cycle.windows([0]) }
}

@Test func ordinaryReadsDoNotPrepareOrWaitForWebContent() throws {
    let windows = [Node(role: "AXWindow")]
    let result = try Reader.preparedSnapshot(.none,
        prepare: { Issue.record("Ordinary reads must not enable Chromium"); return .failure }, snapshot: { windows },
        pause: { _ in Issue.record("Ordinary reads must not wait") })
    #expect(result == windows)
}

@Test func chromiumPreparationWaitsForContentAndReportsTimeoutsAndFailures() throws {
    let empty = [Node(role: "AXWindow")]
    let ready = [Node(role: "AXWindow", children: [Node(role: "AXWebArea", children: [Node(role: "AXStaticText", value: "ready")])])]
    var time = Date(timeIntervalSince1970: 0)
    var reads = 0, preparations = 0
    let result = try Reader.preparedSnapshot(.chromium(timeout: 1), prepare: { preparations += 1; return .success }, snapshot: {
        reads += 1
        return reads == 1 ? empty : ready
    }, now: { time }, pause: { time.addTimeInterval($0) })
    #expect(result == ready && reads == 3 && preparations == 1)
    #expect(throws: ReaderError.webContentTimedOut) {
        try Reader.preparedSnapshot(.chromium(timeout: 1), prepare: { .success }, snapshot: { empty },
                                    now: { time }, pause: { time.addTimeInterval($0) })
    }
    enum Failure: Error { case prepare, read }
    #expect(throws: Failure.prepare) {
        try Reader.preparedSnapshot(.chromium(), prepare: { throw Failure.prepare }, snapshot: { Issue.record("Unexpected read"); return [] })
    }
    #expect(throws: Failure.read) {
        try Reader.preparedSnapshot(.chromium(), prepare: { .success }, snapshot: { throw Failure.read })
    }
}

@Test func unsupportedChromiumPreparationStillRequiresReadableContent() throws {
    let ready = [Node(role: "AXWebArea", children: [Node(role: "AXStaticText", value: "ready")])]
    var time = Date(timeIntervalSince1970: 0)
    #expect(try Reader.preparedSnapshot(.chromium(), prepare: { .attributeUnsupported }, snapshot: { ready },
        now: { time }, pause: { time.addTimeInterval($0) }) == ready)
    #expect(throws: ReaderError.webContentTimedOut) {
        try Reader.preparedSnapshot(.chromium(timeout: 0.1), prepare: { .attributeUnsupported }, snapshot: { [] },
            now: { time }, pause: { time.addTimeInterval($0) })
    }
    #expect(throws: ReaderError.acquisitionFailed(operation: "enable AXManualAccessibility", code: AXError.cannotComplete.rawValue)) {
        try Reader.preparedSnapshot(.chromium(), prepare: { .cannotComplete }, snapshot: {
            Issue.record("Failed preparation must not be ignored")
            return ready
        })
    }
}
