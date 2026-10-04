import AXTree
import ApplicationServices
import Foundation

private enum SnapshotAttributes {
    static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, "AXDOMIdentifier", "AXDOMClassList", kAXChildrenAttribute, "AXFrame",
    ]
    static let webAttributes = [
        "AXURL", "AXValueDescription", "AXPlaceholderValue", "AXEnabled", "AXSelected",
        "AXExpanded", "AXRequired", "AXRowIndexRange", "AXColumnIndexRange",
        "AXColumnHeaderUIElements", "AXRowHeaderUIElements",
    ]
}

/// All traversal, including referenced headers, shares one acquisition budget.
struct SnapshotCapture<Element> {
    var includeWebSemantics = false
    var remainingNodes = 50_000
    var depthLimit = 512
    var values: (Element, [String]) throws -> [Any?]
    var names: (Element) throws -> [String]

    mutating func windows(_ elements: [Element]) throws -> [Node] {
        try elements.map { try read($0) }
    }

    private mutating func consume(depth: Int) throws {
        guard depth < depthLimit else { throw ReaderError.depthLimitExceeded }
        guard remainingNodes > 0 else { throw ReaderError.nodeLimitExceeded }
        remainingNodes -= 1
    }

    private mutating func read(_ element: Element, depth: Int = 0) throws -> Node {
        try consume(depth: depth)
        let values = try values(element, SnapshotAttributes.attributes + (includeWebSemantics ? SnapshotAttributes.webAttributes : []))
        func string(_ index: Int) -> String? {
            guard index < values.count, let text = values[index] as? String, !text.isEmpty else { return nil }
            return text
        }
        guard let role = string(0) else { throw ReaderError.invalidAttribute(kAXRoleAttribute) }
        var node = Node(
            role: role,
            subrole: string(1),
            title: string(2),
            value: string(3),
            description: string(4),
            domID: string(5),
            domClasses: values.count > 6 ? (values[6] as? [String]) ?? [] : []
        )
        if includeWebSemantics {
            if node.value == nil, values.count > 3, let number = values[3] as? NSNumber {
                node.value = number.stringValue
            }
            func bool(_ index: Int) -> Bool? {
                index < values.count ? (values[index] as? NSNumber)?.boolValue : nil
            }
            func range(_ index: Int) -> CFRange? {
                guard index < values.count, CFGetTypeID(values[index] as CFTypeRef) == AXValueGetTypeID() else { return nil }
                var result = CFRange()
                return AXValueGetValue(values[index] as! AXValue, .cfRange, &result) ? result : nil
            }
            func headers(_ index: Int) throws -> [String]? {
                guard index < values.count, let elements = values[index] as? [Element], !elements.isEmpty else { return nil }
                return try elements.map { try headerText($0, depth: depth + 1) }.filter { !$0.isEmpty }
            }
            var web = WebAttributes()
            if values.count > 9 { web.url = (values[9] as? URL)?.absoluteString ?? string(9) }
            web.valueDescription = string(10)
            web.placeholder = string(11)
            web.enabled = bool(12)
            web.selected = bool(13)
            // Chromium can return false for AXExpanded even on elements that do not expose it.
            if bool(14) != nil {
                if try names(element).contains("AXExpanded") { web.expanded = bool(14) }
            }
            web.required = bool(15)
            let row = range(16), column = range(17)
            web.rowIndex = row?.location
            web.rowSpan = row?.length
            web.columnIndex = column?.location
            web.columnSpan = column?.length
            web.columnHeaders = try headers(18)
            web.rowHeaders = try headers(19)
            node.web = web
        }
        if values.count > 8, CFGetTypeID(values[8] as CFTypeRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(values[8] as! AXValue, .cgRect, &rect) { node.frame = rect }
        }
        if values.count > 7, let rawChildren = values[7] {
            guard let children = rawChildren as? [Element] else { throw ReaderError.invalidAttribute(kAXChildrenAttribute) }
            for child in children {
                node.children.append(try read(child, depth: depth + 1))
            }
        }
        return node
    }

    private mutating func headerText(_ element: Element, depth: Int) throws -> String {
        try consume(depth: depth)
        let values = try values(element, ["AXTitle", "AXValue", "AXDescription", "AXChildren"])
        for value in values.prefix(3) {
            if let text = value as? String, !text.isEmpty { return text }
        }
        guard values.count > 3, let children = values[3] as? [Element] else { return "" }
        return try children.map { try headerText($0, depth: depth + 1) }.joined()
    }
}
