import AXTree
import Foundation
import Testing

@Test func preservesEveryCapturedAttributeThroughAJSONRoundTrip() throws {
    let windows = [Node(role: "AXWindow", subrole: "AXStandardWindow", title: "Synthetic window",
                        value: "", description: "日本語\n\"quoted\"", domID: "example", domClasses: ["one", "two"],
                        frame: CGRect(x: -12.5, y: 8.25, width: 640.5, height: 1), children: [
                            Node(role: "AXGroup", children: [Node(role: "AXStaticText", value: "child")]),
                            Node(role: "AXUnknown")
                        ]), Node(role: "AXWindow")]
    let restored = try JSONDecoder().decode([Node].self, from: JSONEncoder().encode(windows))
    #expect(restored == windows)
}

@Test func webAttributesRoundTripAndLegacySnapshotsStillDecode() throws {
    var attributes = WebAttributes()
    attributes.url = "https://example.com/"
    attributes.expanded = false
    attributes.selected = true
    attributes.columnIndex = 2
    attributes.rowSpan = 3
    attributes.columnHeaders = ["Price"]
    let node = Node(role: "AXLink", title: "Example", web: attributes)
    #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node)) == node)
    let legacy = Data(#"{"role":"AXStaticText","value":"Legacy","domClasses":[],"children":[]}"#.utf8)
    #expect(try JSONDecoder().decode(Node.self, from: legacy).web == nil)
}
