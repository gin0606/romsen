import CoreGraphics

/// A point-in-time copy of one accessibility element and its subtree.
public struct Node: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var description: String?
    /// The DOM `id` of the backing element. Only web-based apps expose it.
    public var domID: String?
    /// The DOM class list of the backing element. Only web-based apps expose it.
    public var domClasses: [String]
    /// The element's rectangle in screen coordinates, with y growing downward. Apps may clip it
    /// to the visible area, so an element scrolled out of view can report a flattened rectangle.
    /// Slack does this to rows rendered outside the viewport: their descendants keep their true
    /// x range but all report the same one-point-high y range at the edge of the list.
    public var frame: CGRect?
    public var children: [Node]

    public init(
        role: String,
        subrole: String? = nil,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        domID: String? = nil,
        domClasses: [String] = [],
        frame: CGRect? = nil,
        children: [Node] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.description = description
        self.domID = domID
        self.domClasses = domClasses
        self.frame = frame
        self.children = children
    }

    public func hasClass(_ name: String) -> Bool {
        domClasses.contains(name)
    }

    /// The topmost matching nodes in document order. A match's own subtree is not searched.
    public func all(where matches: (Node) -> Bool) -> [Node] {
        var found: [Node] = []
        collect(into: &found, where: matches)
        return found
    }

    public func first(where matches: (Node) -> Bool) -> Node? {
        if matches(self) { return self }
        for child in children {
            if let hit = child.first(where: matches) { return hit }
        }
        return nil
    }

    public var nodeCount: Int {
        children.reduce(1) { $0 + $1.nodeCount }
    }

    /// One line per node, indented by depth, with every captured attribute.
    public func outline() -> String {
        var lines: [String] = []
        appendOutline(to: &lines, depth: 0)
        return lines.joined(separator: "\n")
    }

    private func collect(into found: inout [Node], where matches: (Node) -> Bool) {
        if matches(self) {
            found.append(self)
            return
        }
        for child in children {
            child.collect(into: &found, where: matches)
        }
    }

    private func appendOutline(to lines: inout [String], depth: Int) {
        var line = String(repeating: " ", count: depth) + role
        if let subrole { line += "/\(subrole)" }
        if let title { line += " title=\(title.debugDescription)" }
        if let value { line += " value=\(value.debugDescription)" }
        if let description { line += " desc=\(description.debugDescription)" }
        if let domID { line += " id=\(domID)" }
        if !domClasses.isEmpty { line += " class=\(domClasses.joined(separator: "."))" }
        lines.append(line)
        for child in children {
            child.appendOutline(to: &lines, depth: depth + 1)
        }
    }
}
