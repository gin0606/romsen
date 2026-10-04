import AXTree
import Foundation
import Testing

@testable import RomsenChrome

private func text(_ value: String) -> Node { Node(role: "AXStaticText", value: value) }
private func group(_ children: [Node]) -> Node { Node(role: "AXGroup", children: children) }
private func web(_ configure: (inout WebAttributes) -> Void) -> WebAttributes {
    var attributes = WebAttributes()
    configure(&attributes)
    return attributes
}
private func render(_ nodes: [Node]) -> String { ChromeRenderer.render(Node(role: "AXWebArea", children: nodes)) }

@Test func chromeKeepsSentencesHeadingsLinksAndCodeTogether() {
    let output = render([
        Node(role: "AXHeading", value: "2", children: [text("Delivery")]),
        group([text("Choose "), Node(role: "AXGroup", subrole: "AXStrongStyleGroup", children: [text("Express")]),
               text(" for "), Node(role: "AXLink", title: "two days", web: web { $0.url = "https://example.com/delivery" },
                                   children: [text("two days")]), text(". Next sentence.")]),
        group([text("日本語の"), Node(role: "AXGroup", subrole: "AXEmphasisStyleGroup", children: [text("強調")]), text("です。")]),
        group([text("Run "), Node(role: "AXGroup", subrole: "AXCodeStyleGroup", children: [text("ship --fast")]), text(" now.")]),
        Node(role: "AXGroup", subrole: "AXCodeStyleGroup", children: [text("first\n  second `value`")]),
    ])
    #expect(output == """
        ## Delivery

        Choose **Express** for [two days](<https://example.com/delivery>). Next sentence.

        日本語の*強調*です。

        Run ` ship --fast ` now.

        ```
        first
          second `value`
        ```
        """)
}

@Test func chromeKeepsLabelsValuesAndStatesWithoutReplacingButtonNamesWithTheirIcons() {
    let output = render([
        group([text("City "), Node(role: "AXTextField", title: "City", value: "Kyoto", web: web { $0.required = true })]),
        Node(role: "AXPopUpButton", title: "Plan", value: "Express", web: web { $0.expanded = false },
             children: [Node(role: "AXMenuItem", value: "Express")]),
        Node(role: "AXCheckBox", title: "Updates", value: "1"),
        Node(role: "AXCheckBox", title: "Gift", value: "0"),
        Node(role: "AXCheckBox", title: "Partial", value: "2"),
        Node(role: "AXCheckBox", title: "Legacy"),
        Node(role: "AXRadioButton", subrole: "AXTabButton", title: "Summary", value: "1", web: web { $0.selected = true }),
        Node(role: "AXSlider", title: "Volume", value: "70", web: web { $0.valueDescription = "70 percent" }),
        Node(role: "AXButton", title: "Account", web: web { $0.enabled = false }, children: [Node(role: "AXImage", title: "Avatar")]),
        Node(role: "AXButton", title: "Details", web: web { $0.expanded = true }),
    ])
    #expect(output.contains("[Input: City = Kyoto (required)]"))
    #expect(!output.contains("City\n"))
    #expect(output.contains("[Select: Plan = Express (collapsed)]"))
    #expect(output.contains("[Checkbox: Updates (checked)]"))
    #expect(output.contains("[Checkbox: Gift (unchecked)]"))
    #expect(output.contains("[Checkbox: Partial (mixed)]"))
    #expect(output.contains("[Checkbox: Legacy (state unknown)]"))
    #expect(output.contains("[Tab: Summary (selected)]"))
    #expect(output.contains("[Slider: Volume = 70 percent]"))
    #expect(output.contains("[Button: Account (disabled)]"))
    #expect(!output.contains("Avatar"))
    #expect(output.contains("[Button: Details (expanded)]"))
}

@Test func chromeKeepsNestedListOrderAndDestinations() {
    let link = Node(role: "AXLink", title: "Details", web: web { $0.url = "https://example.com/details" }, children: [text("Details")])
    let output = render([Node(role: "AXList", children: [
        group([Node(role: "AXListMarker", value: "3. "), text("Choose"),
               Node(role: "AXList", children: [link])]),
        group([Node(role: "AXListMarker", value: "4. "), text("Confirm")]),
    ])])
    #expect(output == "3. Choose\n\n   - [Details](<https://example.com/details>)\n4. Confirm")
}

private func cell(_ value: String, row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1) -> Node {
    Node(role: "AXCell", web: web {
        $0.rowIndex = row; $0.columnIndex = column; $0.rowSpan = rowSpan; $0.columnSpan = columnSpan
    }, children: [text(value)])
}

@Test func chromeTablesPreserveHeaderValuePairsAndOmitDuplicateColumnTrees() {
    let headers = [cell("", row: 0, column: 0), cell("Price", row: 0, column: 1), cell("Arrival", row: 0, column: 2)]
    let data = [cell("Express", row: 1, column: 0), cell("$12", row: 1, column: 1), cell("2 days", row: 1, column: 2)]
    let table = Node(role: "AXTable", title: "Plans", web: web { $0.columnHeaders = ["Price", "Arrival"] }, children: [
        group([text("Plans")]), Node(role: "AXRow", children: headers), Node(role: "AXRow", children: data),
        Node(role: "AXColumn", children: [headers[0], data[0]]), group(headers),
    ])
    #expect(render([table]) == """
        Table: Plans

        |  | Price | Arrival |
        | --- | --- | --- |
        | Express | $12 | 2 days |
        """)
    var headerless = table
    headerless.web = nil
    #expect(render([headerless]).contains("| Column 1 | Column 2 | Column 3 |"))
    #expect(render([headerless]).contains("|  | Price | Arrival |"))
}

@Test func chromeMergedAndSparseTablesKeepCellPositionsInsteadOfShiftingValues() {
    let table = Node(role: "AXTable", children: [
        Node(role: "AXRow", children: [cell("Combined", row: 0, column: 0, columnSpan: 2), cell("Other", row: 0, column: 2)]),
        Node(role: "AXRow", children: [cell("Shared", row: 1, column: 0, rowSpan: 2), cell("Last", row: 1, column: 2)]),
        Node(role: "AXRow", children: [cell("Middle", row: 2, column: 1)]),
    ])
    let output = render([table])
    #expect(output.contains("Row 1:\n- columns 1–2: Combined\n- column 3: Other"))
    #expect(output.contains("Row 2:\n- column 1, spans 2 rows: Shared\n- column 3: Last"))
    #expect(output.contains("Row 3:\n- column 2: Middle"))
}

@Test func chromeRegionsRetainContextAndRicherAccessibleNames() {
    let output = render([
        Node(role: "AXGroup", subrole: "AXLandmarkNavigation", title: "Site", children: [text("Navigation content")]),
        Node(role: "AXGroup", subrole: "AXLandmarkMain", children: [
            Node(role: "AXGroup", title: "12 views", children: [text("12")]),
            Node(role: "AXGroup", title: "Results", children: [Node(role: "AXHeading", value: "2", children: [text("Entry")])]),
            group([text("Repeated")]), group([text("Repeated")]),
        ]),
        Node(role: "AXGroup", subrole: "AXApplicationDialog", title: "Confirm", children: [text("Save changes?")]),
    ])
    #expect(output.contains("[Navigation — Site]\n\nNavigation content\n\n[/Navigation]"))
    #expect(output.contains("[Main]\n\n12 views\n\nResults:\n\n## Entry"))
    #expect(!output.contains("12 views:\n\n12"))
    #expect(output.contains("Repeated\n\nRepeated"))
    #expect(output.contains("[Dialog — Confirm]\n\nSave changes?\n\n[/Dialog]"))
}

@Test func chromeWebAttributesRoundTripAndLegacySnapshotsStillDecode() throws {
    let node = Node(role: "AXLink", title: "Example", web: web {
        $0.url = "https://example.com/"; $0.expanded = false; $0.selected = true
        $0.columnIndex = 2; $0.rowSpan = 3; $0.columnHeaders = ["Price"]
    })
    #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node)) == node)
    let legacy = Data(#"{"role":"AXStaticText","value":"Legacy","domClasses":[],"children":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(Node.self, from: legacy)
    #expect(decoded.web == nil)
    #expect(render([decoded]) == "Legacy")
}

@Test func chromeSeparatesVisuallySpacedInlineElementsWithoutBreakingAdjacentJapanese() {
    var first = Node(role: "AXLink", title: "Home", web: web { $0.url = "https://example.com/" })
    first.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
    var second = text("Guide")
    second.frame = CGRect(x: 60, y: 0, width: 40, height: 20)
    var third = text("次の")
    third.frame = CGRect(x: 0, y: 40, width: 40, height: 20)
    var fourth = text("段落")
    fourth.frame = CGRect(x: 40, y: 40, width: 40, height: 20)
    #expect(render([first, second, third, fourth]) == "[Home](<https://example.com/>) Guide\n\n次の段落")
}

@Test func chromeLinksKeepBothAccessibleLabelsAndDistinctChildContent() {
    let destination = web { $0.url = "https://example.com/item" }
    let output = render([
        group([Node(role: "AXLink", title: "Open item", web: destination, children: [text("Delivery options")])]),
        group([Node(role: "AXLink", title: "Delivery options — 5 minutes", web: destination, children: [text("Delivery options")])]),
    ])
    #expect(output.contains("[Open item — Delivery options](<https://example.com/item>)"))
    #expect(output.contains("[Delivery options — 5 minutes](<https://example.com/item>)"))
    #expect(!output.contains("5 minutes — Delivery options"))
}
