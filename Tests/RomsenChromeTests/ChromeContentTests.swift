import AXTree
import Foundation
import Testing

@testable import RomsenChrome

private func region(_ subrole: String, _ value: String, children: [Node] = []) -> Node {
    Node(role: "AXGroup", subrole: subrole, children: [Node(role: "AXStaticText", value: value)] + children)
}

private func readPage(_ children: [Node], arguments: [String] = []) throws -> String {
    var web = WebAttributes()
    web.url = "https://example.com/page"
    let windows = [Node(role: "AXWindow", children: [
        Node(role: "AXWebArea", title: "Example", web: web, children: children)
    ])]
    return try Chrome.parse(arguments).read { windows }
}

@Test func chromeDefaultsToMainRegionsAndDialogsWithoutDroppingArticleSupplements() throws {
    let children = [
        region("AXLandmarkNavigation", "site links"),
        region("AXLandmarkComplementary", "sidebar links"),
        Node(role: "AXGroup", title: "outer wrapper", children: [
            region("AXLandmarkMain", "main article", children: [region("AXLandmarkComplementary", "supporting table")]),
            region("AXLandmarkMain", "second main region"),
        ]),
        region("AXLandmarkBanner", "banner", children: [region("AXApplicationDialog", "open dialog")]),
        region("AXLandmarkContentInfo", "site footer"),
        Node(role: "AXStaticText", value: "unlabelled surrounding content"),
    ]
    let output = try readPage(children)
    for text in ["# Example", "https://example.com/page", "main article", "supporting table", "second main region", "open dialog"] {
        #expect(output.contains(text))
    }
    for text in ["site links", "sidebar links", "outer wrapper", "banner", "site footer", "unlabelled surrounding content"] {
        #expect(!output.contains(text))
    }
    let wholePage = try readPage(children, arguments: ["--all"])
    #expect(wholePage.contains("site links"))
    #expect(wholePage.contains("sidebar links"))
    #expect(wholePage.contains("unlabelled surrounding content"))
    #expect(try readPage(children, arguments: ["--raw"]).contains("sidebar links"))
}

@Test func chromeWithoutMainKeepsUnidentifiedContentAndRemovesKnownPeripheralRegions() throws {
    let peripheral = ["AXLandmarkNavigation", "AXLandmarkComplementary", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkSearch"]
    var children = peripheral.map { region($0, "omit " + $0) }
    children += [
        Node(role: "AXGroup", children: [Node(role: "AXStaticText", value: "unlabelled article")]),
        region("AXLandmarkForm", "form content"),
        region("AXApplicationAlertDialog", "confirm changes"),
    ]
    let output = try readPage(children)
    #expect(!output.contains("omit "))
    #expect(output.contains("unlabelled article"))
    #expect(output.contains("form content"))
    #expect(output.contains("confirm changes"))
}

@Test func chromeScopesMainSelectionToEachDocument() throws {
    let frame = Node(role: "AXWebArea", title: "Embedded", children: [
        region("AXLandmarkNavigation", "frame navigation"), region("AXLandmarkMain", "frame content")
    ])
    let children = [Node(role: "AXStaticText", value: "outer article"), frame,
                    region("AXLandmarkComplementary", "outer sidebar", children: [
                        region("AXLandmarkMain", "misplaced main")
                    ])]
    let output = try readPage(children)
    #expect(output.contains("outer article"))
    #expect(output.contains("frame content"))
    #expect(!output.contains("frame navigation"))
    #expect(!output.contains("outer sidebar"))
    #expect(!output.contains("misplaced main"))
    #expect(try readPage(children, arguments: ["--all"]).contains("frame navigation"))
}

@Test func chromeSavesTheWholeWindowSoReplayCanChangeContentScope() throws {
    let windows = [Node(role: "AXWindow", children: [Node(role: "AXWebArea", children: [
        region("AXLandmarkMain", "article"), region("AXLandmarkComplementary", "saved sidebar")
    ])])]
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let output = try Chrome.parse(["--save-snapshot", file.path]).read { windows }
    #expect(!output.contains("saved sidebar"))
    #expect(try JSONDecoder().decode([Node].self, from: Data(contentsOf: file)) == windows)
    let replay = try Chrome.parse(["--from-snapshot", file.path, "--all"]).read {
        Issue.record("Saved reads must not access Chrome")
        return []
    }
    #expect(replay.contains("article"))
    #expect(replay.contains("saved sidebar"))
}
