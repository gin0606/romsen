import AXTree
import Foundation
import Testing

@testable import RomsenChrome

private func chromeWindow(_ children: [Node]) -> [Node] {
    [Node(role: "AXWindow", title: "Browser window", children: [
        Node(role: "AXToolbar", children: [Node(role: "AXButton", title: "Browser toolbar")]),
        Node(role: "AXTabGroup", children: [Node(role: "AXRadioButton", title: "Background tab")]),
        Node(role: "AXGroup", children: [Node(role: "AXWebArea", title: "Example page", children: children)])
    ])]
}

@Test func chromeReadsPageTextWithoutBrowserControlsOrDuplicateContainerLabels() throws {
    let windows = chromeWindow([
        Node(role: "AXHeading", title: "Heading", children: [Node(role: "AXStaticText", value: "Heading")]),
        Node(role: "AXLink", title: "Read more", children: [
            Node(role: "AXGroup", children: [Node(role: "AXStaticText", value: "Read more")])
        ]),
        Node(role: "AXButton", title: "Continue", description: "Continue"),
        Node(role: "AXImage", description: "Example diagram"),
        Node(role: "AXTextField", value: "日本語の入力"),
        Node(role: "AXTextField", subrole: "AXSecureTextField", value: "secret"),
        Node(role: "AXWebArea", children: [Node(role: "AXStaticText", value: "Frame text")]),
        Node(role: "AXStaticText", value: "Repeated"),
        Node(role: "AXStaticText", value: "Repeated"),
        Node(role: "AXGroup", value: "  ", description: "Fallback label")
    ])
    let command = try Chrome.parse([])
    let output = try command.read { windows }
    #expect(output.contains("## Heading"))
    #expect(output.contains("[Link: Read more]"))
    #expect(output.contains("[Button: Continue]"))
    #expect(output.contains("[Image: Example diagram]"))
    #expect(output.contains("[Input: unlabelled = 日本語の入力]"))
    #expect(!output.contains("secret"))
    #expect(output.contains("[Frame]\n\nFrame text\n\n[/Frame]"))
    #expect(output.contains("RepeatedRepeated"))
    #expect(output.contains("Fallback label"))
    #expect(!output.contains("Browser toolbar"))
    #expect(!output.contains("Background tab"))

}

@Test func chromeRejectsMissingOrAmbiguousWindowsButAllowsAnEmptyPage() throws {
    let command = try Chrome.parse([])
    for windows in [[], [Node(role: "AXWindow")], chromeWindow([]) + chromeWindow([]),
                    [Node(role: "AXWindow", children: [Node(role: "AXWebArea"), Node(role: "AXWebArea")])]] {
        #expect(throws: (any Error).self) { try command.read { windows } }
    }
    #expect(try command.read { chromeWindow([]) } == "# Example page")
}

@Test func chromeSavesAndReplaysWithoutAccessingTheBrowser() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("page.json")
    let windows = chromeWindow([Node(role: "AXStaticText", value: "Page body")])
    let save = try Chrome.parse(["--save-snapshot", file.path])
    let output = try save.read { windows }
    #expect(try JSONDecoder().decode([Node].self, from: Data(contentsOf: file)) == windows)
    let replay = try Chrome.parse(["--from-snapshot", file.path])
    #expect(try replay.read {
        Issue.record("Replay must not access Chrome")
        return []
    } == output)
    let raw = try Chrome.parse(["--from-snapshot", file.path, "--raw"])
    #expect(try raw.read { [] } == windows[0].outline())
    try Data("invalid json".utf8).write(to: file)
    #expect(throws: (any Error).self) { try replay.read { [] } }
    try FileManager.default.removeItem(at: file)
    #expect(throws: (any Error).self) { try replay.read { [] } }
    let unwritable = try Chrome.parse(["--save-snapshot", directory.path])
    #expect(throws: (any Error).self) { try unwritable.read { windows } }
}
