import AXTree

enum ChromeContent {
    private static let peripheral: Set<String> = [
        "AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo",
        "AXLandmarkComplementary", "AXLandmarkSearch",
    ]
    private static let dialogs: Set<String> = ["AXApplicationDialog", "AXApplicationAlertDialog"]

    static func main(_ page: Node) -> Node {
        let regions = page.children.flatMap { selectedRegions($0) }
        var selected = page
        selected.children = regions.contains { $0.subrole == "AXLandmarkMain" }
            ? regions : page.children.flatMap(removingPeripheral)
        selected.children = selected.children.map(selectingFrames)
        return selected
    }

    private static func selectedRegions(_ node: Node, inPeripheral: Bool = false) -> [Node] {
        // A frame's main region describes that document, not its containing page.
        if node.role == "AXWebArea" { return [] }
        if dialogs.contains(node.subrole ?? "") { return [node] }
        let inPeripheral = inPeripheral || peripheral.contains(node.subrole ?? "")
        if node.subrole == "AXLandmarkMain", !inPeripheral { return [node] }
        return node.children.flatMap { selectedRegions($0, inPeripheral: inPeripheral) }
    }

    private static func removingPeripheral(_ node: Node) -> [Node] {
        if node.role == "AXWebArea" || dialogs.contains(node.subrole ?? "") { return [node] }
        if peripheral.contains(node.subrole ?? "") {
            return selectedRegions(node).filter { dialogs.contains($0.subrole ?? "") }
        }
        var selected = node
        selected.children = node.children.flatMap(removingPeripheral)
        if !node.children.isEmpty, selected.children.isEmpty { return [] }
        return [selected]
    }

    private static func selectingFrames(_ node: Node) -> Node {
        if node.role == "AXWebArea" { return main(node) }
        var selected = node
        selected.children = node.children.map(selectingFrames)
        return selected
    }
}
