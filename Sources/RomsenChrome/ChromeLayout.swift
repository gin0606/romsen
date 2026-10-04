import AXTree
import CoreGraphics

enum ChromeLayout {
    /// Reorder only contiguous sibling blocks in an unambiguous vertical stack.
    /// Headings, controls, lists and tables anchor the surrounding content.
    static func ordered(_ nodes: [Node]) -> [Node] {
        var result: [Node] = [], run: [Node] = []
        func flush() {
            let frames = run.compactMap { usableFrame($0) }
            let left = frames.map(\.minX).max() ?? 0
            let right = frames.map(\.maxX).min() ?? 0
            let width = frames.map(\.width).min() ?? 0
            let sorted = zip(run, frames).sorted { $0.1.minY < $1.1.minY }
            let separated = zip(sorted, sorted.dropFirst()).allSatisfy { $0.1.maxY <= $1.1.minY }
            if run.count > 1, right - left >= width / 2, separated {
                result.append(contentsOf: sorted.map(\.0))
            } else {
                result.append(contentsOf: run)
            }
            run.removeAll(keepingCapacity: true)
        }
        for node in nodes {
            if node.role == "AXGroup", [nil, "AXEmptyGroup", "AXDocumentArticle"].contains(node.subrole),
               usableFrame(node) != nil {
                run.append(node)
            } else {
                flush()
                result.append(node)
            }
        }
        flush()
        return result
    }

    static func isAnonymousWrapper(_ node: Node) -> Bool {
        node.role == "AXGroup" && [nil, "AXEmptyGroup"].contains(node.subrole)
            && [node.title, node.description, node.value].allSatisfy { $0?.isEmpty != false }
            && !node.children.isEmpty
    }

    /// Geometry confirms that an otherwise anonymous group belongs to a neighbouring text run.
    static func joinsInline(_ node: Node, beside neighbour: Node) -> Bool {
        guard isAnonymousWrapper(node), node.children.allSatisfy(isInlineContent),
              let frame = usableFrame(node), let adjacent = usableFrame(neighbour),
              frame.height <= adjacent.height * 1.75,
              abs(frame.midY - adjacent.midY) <= min(frame.height, adjacent.height) / 2 else { return false }
        let gap = max(frame.minX - adjacent.maxX, adjacent.minX - frame.maxX)
        return gap >= -2 && gap <= max(frame.height, adjacent.height)
    }

    private static func isInlineContent(_ node: Node) -> Bool {
        switch node.role {
        case "AXStaticText": return node.value?.contains("\n") != true
        case "AXLink", "AXImage": return true
        case "AXGroup":
            let style = ["AXStrongStyleGroup", "AXEmphasisStyleGroup", "AXCodeStyleGroup"].contains(node.subrole)
            return (style || isAnonymousWrapper(node)) && !node.children.isEmpty && node.children.allSatisfy(isInlineContent)
        default: return false
        }
    }

    private static func usableFrame(_ node: Node) -> CGRect? {
        guard let frame = node.frame, frame.width > 1, frame.height > 1,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite) else { return nil }
        return frame
    }
}
