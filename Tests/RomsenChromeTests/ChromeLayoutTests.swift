import AXTree
import Foundation
import Testing

@testable import RomsenChrome

private func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat = 80) -> Node {
    Node(role: "AXStaticText", value: value, frame: CGRect(x: x, y: y, width: width, height: 20))
}

private func card(_ title: String, _ body: String, x: CGFloat, y: CGFloat, height: CGFloat = 80) -> Node {
    Node(role: "AXGroup", subrole: "AXDocumentArticle", frame: CGRect(x: x, y: y, width: 200, height: height), children: [
        Node(role: "AXHeading", value: "2", children: [text(title, x: x, y: y)]),
        Node(role: "AXGroup", children: [text(body, x: x, y: y + 30)]),
    ])
}

private func render(_ children: [Node]) -> String {
    ChromeRenderer.render(Node(role: "AXWebArea", children: children))
}

@Test func chromeReadsVerticalCardsInVisualOrderWithoutInterleavingTheirContent() {
    let bottom = card("Second step", "Confirm destination", x: -200, y: 200)
    let top = card("First step", "Choose a plan", x: -200, y: 100)
    #expect(render([bottom, top]) == """
        [Article]

        ## First step

        Choose a plan

        [/Article]

        [Article]

        ## Second step

        Confirm destination

        [/Article]
        """)
}

@Test func chromeKeepsAXOrderWhenGeometryCannotEstablishAVerticalStack() {
    let original = card("First in AX", "Original body", x: 0, y: 100)
    for other in [
        card("Second in AX", "Other body", x: 250, y: 0), // Separate columns.
        card("Second in AX", "Other body", x: 0, y: 80), // Overlapping blocks.
        card("Second in AX", "Other body", x: 0, y: 0, height: 1), // Clipped offscreen.
        Node(role: "AXGroup", subrole: "AXDocumentArticle", children: [text("Second in AX", x: 0, y: 0)]),
    ] {
        let output = render([original, other])
        #expect(output.range(of: "First in AX")!.lowerBound < output.range(of: "Second in AX")!.lowerBound)
        #expect(output.range(of: "Original body")!.lowerBound < output.range(of: "Second in AX")!.lowerBound)
    }
}

@Test func chromeDoesNotMoveBlocksAcrossHeadingsOrReorderNumberedListItemsAndTableRows() {
    let first = card("Before heading", "First body", x: 0, y: 300)
    let second = card("After heading", "Second body", x: 0, y: 0)
    let heading = Node(role: "AXHeading", value: "1", children: [text("Boundary", x: 0, y: 200)])
    let output = render([first, heading, second])
    #expect(output.range(of: "Before heading")!.lowerBound < output.range(of: "Boundary")!.lowerBound)
    #expect(output.range(of: "Boundary")!.lowerBound < output.range(of: "After heading")!.lowerBound)
    let list = Node(role: "AXList", children: [
        Node(role: "AXGroup", frame: CGRect(x: 0, y: 100, width: 200, height: 20), children: [
            Node(role: "AXListMarker", value: "1."), text("Choose", x: 20, y: 100),
        ]),
        Node(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 200, height: 20), children: [
            Node(role: "AXListMarker", value: "2."), text("Confirm", x: 20, y: 0),
        ]),
    ])
    #expect(render([list]) == "1. Choose\n2. Confirm")
    let table = Node(role: "AXTable", children: [
        Node(role: "AXRow", frame: CGRect(x: 0, y: 100, width: 200, height: 20), children: [
            Node(role: "AXCell", children: [text("First row", x: 0, y: 100)]),
        ]),
        Node(role: "AXRow", frame: CGRect(x: 0, y: 0, width: 200, height: 20), children: [
            Node(role: "AXCell", children: [text("Second row", x: 0, y: 0)]),
        ]),
    ])
    #expect(render([table]) == "| Column 1 |\n| --- |\n| First row |\n| Second row |")
}

@Test func chromeKeepsAnonymousInlineWrappersInsideEnglishAndJapaneseSentences() {
    let nested = Node(role: "AXGroup", frame: CGRect(x: 80, y: -3, width: 60, height: 26), children: [
        Node(role: "AXGroup", children: [text("Kyoto", x: 80, y: 0, width: 60)]),
    ])
    let styled = Node(role: "AXGroup", frame: CGRect(x: 220, y: -3, width: 100, height: 26), children: [
        Node(role: "AXGroup", subrole: "AXStrongStyleGroup", children: [text("two", x: 220, y: 0, width: 30)]),
        text(" days", x: 250, y: 0, width: 70),
    ])
    #expect(render([text("Delivery to ", x: 0, y: 0), nested, text(" takes ", x: 140, y: 0), styled,
                    text(".", x: 320, y: 0, width: 10)]) == "Delivery to Kyoto takes **two** days.")
    var japanese = nested
    japanese.children = [text("まとまり", x: 80, y: 0, width: 60)]
    #expect(render([text("日本語の", x: 0, y: 0), japanese, text("を保つ。", x: 140, y: 0)]) == "日本語のまとまりを保つ。")
}

@Test func chromeDoesNotMergeDistinctOrUnpositionedGroupsIntoSentences() {
    let before = text("Introduction", x: 0, y: 0)
    for separate in [
        Node(role: "AXGroup", title: "Named section", frame: CGRect(x: 80, y: 0, width: 80, height: 20),
             children: [text("Separate text", x: 80, y: 0)]),
        Node(role: "AXGroup", frame: CGRect(x: 300, y: 0, width: 80, height: 20),
             children: [text("Separate text", x: 300, y: 0)]),
        Node(role: "AXGroup", frame: CGRect(x: 0, y: 100, width: 80, height: 20),
             children: [text("Separate text", x: 0, y: 100)]),
        Node(role: "AXGroup", children: [text("Separate text", x: 80, y: 0)]),
    ] {
        #expect(render([before, separate]).hasPrefix("Introduction\n\n"))
    }
}
