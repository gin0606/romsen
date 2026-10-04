import AXTree
import Foundation

/// Renders the relationships exposed by accessibility without relying on site-specific DOM classes.
enum ChromeRenderer {
    private struct Fragment {
        var text: String
        var inline = false
    }

    static func render(_ page: Node) -> String {
        var parts: [String] = []
        if let title = nonempty(page.title) { parts.append("# \(title)") }
        if let url = page.web?.url { parts.append("URL: \(url)") }
        parts.append(contents(page.children))
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let regions = [
        "AXLandmarkMain": "Main", "AXLandmarkNavigation": "Navigation",
        "AXLandmarkBanner": "Banner", "AXLandmarkContentInfo": "Footer",
        "AXLandmarkComplementary": "Related", "AXLandmarkSearch": "Search",
        "AXLandmarkForm": "Form", "AXLandmarkRegion": "Region",
        "AXDocumentArticle": "Article", "AXApplicationDialog": "Dialog",
        "AXApplicationAlertDialog": "Alert dialog", "AXApplicationAlert": "Alert",
    ]

    private static func fragment(_ node: Node) -> Fragment {
        if node.subrole == "AXSecureTextField" { return Fragment(text: "[Password: concealed]") }
        if let region = regions[node.subrole ?? ""] {
            let label = name(node).flatMap { $0 == region ? nil : " — \($0)" } ?? ""
            let body = contents(node.children)
            return Fragment(text: "[\(region)\(label)]\n\n\(body)\n\n[/\(region)]")
        }
        if let control = control(node) { return Fragment(text: control) }
        switch node.role {
        case "AXStaticText", "AXListMarker":
            return Fragment(text: node.value ?? name(node) ?? "", inline: true)
        case "AXHeading":
            let level = min(6, max(1, Int(node.value ?? "") ?? 2))
            let body = inlineContents(node)
            return Fragment(text: body.isEmpty ? "" : String(repeating: "#", count: level) + " " + body)
        case "AXLink":
            let childText = node.children.map(plainText).joined()
            var label = name(node) ?? childText
            if let childText = nonempty(childText), !label.contains(childText) {
                label += " — " + childText
            }
            if let url = node.web?.url {
                return Fragment(text: "[\(escapeLabel(label.isEmpty ? url : label))](<\(escapeURL(url))>)", inline: true)
            }
            return Fragment(text: "[Link: \(label)]", inline: true)
        case "AXImage":
            return Fragment(text: name(node).map { "[Image: \($0)]" } ?? "", inline: true)
        case "AXTable", "AXGrid":
            return Fragment(text: table(node))
        case "AXList":
            return Fragment(text: list(node))
        case "AXWebArea":
            return Fragment(text: "[Frame]\n\n\(render(node))\n\n[/Frame]")
        case "AXTabGroup":
            return Fragment(text: "[Tabs\(name(node).map { ": \($0)" } ?? "")]\n\n\(contents(node.children))")
        default:
            break
        }
        let body = contents(node.children)
        switch node.subrole {
        case "AXStrongStyleGroup": return Fragment(text: "**\(body)**", inline: true)
        case "AXEmphasisStyleGroup": return Fragment(text: "*\(body)*", inline: true)
        case "AXCodeStyleGroup":
            let code = plainText(node)
            let fence = String(repeating: "`", count: max(code.contains("\n") ? 3 : 1, longestBacktickRun(code) + 1))
            return code.contains("\n")
                ? Fragment(text: "\(fence)\n\(code)\n\(fence)")
                : Fragment(text: "\(fence) \(code) \(fence)", inline: true)
        case "AXBlockQuote":
            return Fragment(text: body.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n"))
        default: break
        }
        if let label = name(node) {
            let plain = plainText(node)
            let onlyText = node.first { !["AXGroup", "AXStaticText"].contains($0.role) } == nil
            if body.isEmpty || (onlyText && nonempty(plain).map { label.contains($0) } == true) {
                return Fragment(text: label)
            }
            // Accessible names can contain units or context absent from child text.
            return Fragment(text: "\(label):\n\n\(body)")
        }
        return Fragment(text: body.isEmpty ? (node.value ?? "") : body)
    }

    private static func contents(_ nodes: [Node]) -> String {
        let nodes = ChromeLayout.ordered(nodes)
        let fragments = nodes.map(fragment)
        var blocks: [String] = [], inline = ""
        var previousInline: Node?
        func flush() {
            if let text = nonempty(inline) { blocks.append(text) }
            inline = ""
            previousInline = nil
        }
        for (index, node) in nodes.enumerated() {
            // A label next to its named input is already represented with that input's value.
            if node.role == "AXStaticText", index + 1 < nodes.count,
               control(nodes[index + 1]) != nil, nonempty(node.value) == name(nodes[index + 1]) { continue }
            var value = fragments[index]
            if !value.inline, ChromeLayout.isAnonymousWrapper(node) {
                let previousJoins = previousInline.map { ChromeLayout.joinsInline(node, beside: $0) } ?? false
                let nextJoins = index + 1 < nodes.count && fragments[index + 1].inline
                    && ChromeLayout.joinsInline(node, beside: nodes[index + 1])
                if previousJoins || nextJoins { value = Fragment(text: inlineWrapperText(node), inline: true) }
            }
            if value.inline {
                if !inline.isEmpty, !value.text.isEmpty,
                   inline.last?.isWhitespace == false, value.text.first?.isWhitespace == false,
                   let previous = previousInline?.frame, let current = node.frame {
                    if current.minY > previous.maxY + 2 { flush() }
                    else if current.minX > previous.maxX + 2 { inline += " " }
                }
                inline += value.text
                previousInline = node
            }
            else if !value.text.isEmpty { flush(); blocks.append(value.text) }
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }

    private static func inlineWrapperText(_ node: Node) -> String {
        node.children.map { child in
            ChromeLayout.isAnonymousWrapper(child) ? inlineWrapperText(child) : fragment(child).text
        }.joined()
    }

    private static func inlineContents(_ node: Node) -> String {
        let body = contents(node.children)
        return body.isEmpty ? (name(node) ?? "") : body.replacingOccurrences(of: "\n\n", with: " ")
    }

    private static func control(_ node: Node) -> String? {
        let kind: String
        switch node.role {
        case "AXButton": kind = "Button"
        case "AXCheckBox": kind = node.subrole == "AXToggle" ? "Toggle" : "Checkbox"
        case "AXRadioButton": kind = node.subrole == "AXTabButton" ? "Tab" : "Radio"
        case "AXTextField", "AXTextArea": kind = "Input"
        case "AXComboBox", "AXPopUpButton": kind = "Select"
        case "AXSlider": kind = "Slider"
        case "AXIncrementor": kind = "Number"
        case "AXSwitch": kind = "Switch"
        default: return nil
        }
        var states: [String] = []
        if kind == "Tab" {
            if let selected = node.web?.selected { states.append(selected ? "selected" : "not selected") }
            else if let value = node.value { states.append(value == "1" ? "selected" : "not selected") }
        } else if ["Checkbox", "Toggle", "Radio", "Switch"].contains(kind) {
            switch node.value {
            case "1": states.append("checked")
            case "0": states.append("unchecked")
            case "2": states.append("mixed")
            default: states.append("state unknown")
            }
        }
        if node.web?.enabled == false { states.append("disabled") }
        if node.web?.required == true { states.append("required") }
        if let expanded = node.web?.expanded { states.append(expanded ? "expanded" : "collapsed") }
        let label = name(node) ?? node.web?.placeholder ?? "unlabelled"
        var result = "[\(kind): \(label)"
        if ["Input", "Select", "Slider", "Number"].contains(kind) {
            result += " = \(node.web?.valueDescription ?? node.value ?? "(empty)")"
        }
        if !states.isEmpty { result += " (\(states.joined(separator: ", ")))" }
        return result + "]"
    }

    private static func list(_ node: Node) -> String {
        node.children.map { item in
            let marker = item.children.first { $0.role == "AXListMarker" }?.value?.trimmingCharacters(in: .whitespaces)
            let prefix = marker.flatMap { $0.first?.isNumber == true ? $0 : nil } ?? "-"
            let body = item.role == "AXGroup"
                ? contents(item.children.filter { $0.role != "AXListMarker" }) : fragment(item).text
            let text = body.isEmpty ? fragment(item).text : body
            let lines = text.components(separatedBy: "\n")
            return "\(prefix) \(lines.first ?? "")" + lines.dropFirst().map {
                $0.isEmpty ? "\n" : "\n" + String(repeating: " ", count: prefix.count + 1) + $0
            }.joined()
        }.joined(separator: "\n")
    }

    private static func table(_ node: Node) -> String {
        // Chromium exposes cells again under AXColumn and a header group. Read rows only.
        func rows(_ root: Node) -> [Node] {
            root.children.flatMap { child -> [Node] in
                if child.role == "AXRow" { return [child] }
                if ["AXColumn", "AXTable", "AXGrid"].contains(child.role) { return [] }
                return rows(child)
            }
        }
        let matrix = rows(node).map { row in row.all { ["AXCell", "AXColumnHeader", "AXRowHeader"].contains($0.role) } }
        guard !matrix.isEmpty else { return "[Table]\n\n" + contents(node.children) }
        let title = name(node).map { "Table: \($0)\n\n" } ?? ""
        let width = matrix.map(\.count).max() ?? 0
        let simple = width > 0 && matrix.allSatisfy { row in
            row.count == width && row.enumerated().allSatisfy { index, cell in
                (cell.web?.rowSpan ?? 1) == 1 && (cell.web?.columnSpan ?? 1) == 1
                    && (cell.web?.columnIndex ?? index) == index
            }
        }
        func cellText(_ cell: Node) -> String {
            let body = contents(cell.children)
            return (body.isEmpty ? (name(cell) ?? cell.value ?? "") : body)
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
        }
        if simple {
            let first = matrix[0].map { plainText($0) }
            let headers = node.web?.columnHeaders ?? []
            let hasHeader = !headers.isEmpty && first.filter { !$0.isEmpty } == headers
            var lines = ["| " + (hasHeader ? matrix[0].map(cellText) : (1...width).map { "Column \($0)" }).joined(separator: " | ") + " |",
                         "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
            for row in matrix.dropFirst(hasHeader ? 1 : 0) { lines.append("| " + row.map(cellText).joined(separator: " | ") + " |") }
            return title + lines.joined(separator: "\n")
        }
        return title + matrix.enumerated().map { rowIndex, row in
            let rowNumber = (row.first?.web?.rowIndex ?? rowIndex) + 1
            return "Row \(rowNumber):\n" + row.enumerated().map { columnIndex, cell in
                let column = (cell.web?.columnIndex ?? columnIndex) + 1
                let span = cell.web?.columnSpan ?? 1
                let position = span > 1 ? "columns \(column)–\(column + span - 1)" : "column \(column)"
                let rowSpan = cell.web?.rowSpan ?? 1
                let headers = ((cell.web?.rowHeaders ?? []) + (cell.web?.columnHeaders ?? [])).joined(separator: " / ")
                return "- \(position)\(rowSpan > 1 ? ", spans \(rowSpan) rows" : "")\(headers.isEmpty ? "" : " (\(headers))"): \(cellText(cell))"
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func plainText(_ node: Node) -> String {
        if node.role == "AXStaticText" { return node.value ?? "" }
        let text = node.children.map(plainText).joined()
        return text.isEmpty ? (name(node) ?? node.value ?? "") : text
    }

    private static func name(_ node: Node) -> String? { nonempty(node.title) ?? nonempty(node.description) }
    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func escapeLabel(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
    private static func escapeURL(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\n", with: "%0A")
    }
    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0, run = 0
        for character in text { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        return longest
    }
}
