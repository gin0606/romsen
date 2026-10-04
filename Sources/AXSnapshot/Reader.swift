import AXTree
import AppKit
import ApplicationServices

public enum ReaderError: Error, CustomStringConvertible {
    case notTrusted
    case notRunning(bundleID: String)
    case noWindows(bundleID: String)
    case noFocusedWindow(bundleID: String)

    public var description: String {
        switch self {
        case .notTrusted:
            """
            Accessibility permission is missing. Grant it to the app that launches this command \
            (your terminal, or the agent's host app) in System Settings > Privacy & Security > Accessibility.
            """
        case .notRunning(let bundleID):
            "No running app with bundle ID \(bundleID)."
        case .noWindows(let bundleID):
            "\(bundleID) has no open windows to read."
        case .noFocusedWindow(let bundleID):
            "\(bundleID) has no focused window to read. Select a browser window and try again."
        }
    }
}

/// Reads the windows of a running app through the Accessibility API. The only things it changes
/// in the target app are the accessibility switch described on `snapshotWindows`, the scroll
/// position through `scrollToVisible`, and whatever `press` clicks. It never focuses or types.
///
/// None of this needs the target app to be frontmost, and none of it brings the app forward.
/// The Accessibility permission is checked against the process that launched this one (the
/// terminal or the agent's host app), not against this binary.
public enum Reader {
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, "AXDOMIdentifier", "AXDOMClassList", kAXChildrenAttribute, "AXFrame",
    ]
    private static let maxNodes = 50_000
    private static let webAttributes = [
        "AXURL", "AXValueDescription", "AXPlaceholderValue", "AXEnabled", "AXSelected",
        "AXExpanded", "AXRequired", "AXRowIndexRange", "AXColumnIndexRange",
        "AXColumnHeaderUIElements", "AXRowHeaderUIElements",
    ]

    /// Chromium-based apps build their accessibility tree only once an assistive client asks for
    /// it, so this sets `AXManualAccessibility` on the app and waits for the web content to
    /// appear. The switch stays on afterwards, which keeps later reads fast.
    ///
    /// Measured on Slack: before the switch the window holds only native chrome and an empty
    /// web area; about three seconds after it, the full tree is there. With the switch already
    /// on, a read takes well under a second. The switch resets when the app restarts.
    public static func snapshotWindows(
        bundleID: String, focusedWindowOnly: Bool = false, includeWebSemantics: Bool = false,
        webContentTimeout: TimeInterval = 10
    ) throws -> [Node] {
        guard AXIsProcessTrusted() else { throw ReaderError.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw ReaderError.notRunning(bundleID: bundleID)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 5)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windows = try readWindows(of: element, bundleID: bundleID, focusedWindowOnly: focusedWindowOnly,
                                      includeWebSemantics: includeWebSemantics)
        // The web content fills in over a few seconds, so wait until two reads in a row agree.
        let deadline = Date().addingTimeInterval(webContentTimeout)
        var previousCount = -1
        while Date() < deadline {
            let count = windows.reduce(0) { $0 + $1.nodeCount }
            if hasWebContent(windows), count == previousCount { break }
            previousCount = count
            Thread.sleep(forTimeInterval: 0.3)
            windows = try readWindows(of: element, bundleID: bundleID, focusedWindowOnly: focusedWindowOnly,
                                      includeWebSemantics: includeWebSemantics)
        }
        return windows
    }

    /// Scrolls the element with this DOM id into view. Returns false if no such element exists
    /// or the app rejects the request.
    ///
    /// This is the only way to scroll a Chromium app through accessibility: its elements expose
    /// the `AXScrollToVisible` action but no scroll position attribute, no scroll bars, and no
    /// page-up or page-down actions. Sending keys would work too, but keys go to whatever has
    /// focus, which in a chat app may be the message composer.
    public static func scrollToVisible(bundleID: String, domID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        var budget = maxNodes
        for window in value as? [AXUIElement] ?? [] {
            if let target = find(domID: domID, in: window, budget: &budget) {
                return AXUIElementPerformAction(target, "AXScrollToVisible" as CFString) == .success
            }
        }
        return false
    }

    /// Clicks the first element with `descendantClass` inside the element with this DOM id.
    /// A press can do anything a click can, so callers must name a control that only navigates.
    ///
    /// Success only means the app accepted the action. Chromium reports success for any element,
    /// including wrappers whose click handler sits on a child, where nothing then happens. So
    /// the element to press has to be the one that handles the click, and callers should confirm
    /// the effect by reading the tree again.
    public static func press(bundleID: String, domID: String, descendantClass: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        var budget = maxNodes
        for window in value as? [AXUIElement] ?? [] {
            if let container = find(domID: domID, in: window, budget: &budget),
                let target = find(domClass: descendantClass, in: container, budget: &budget)
            {
                return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    private static func find(domClass: String, in element: AXUIElement, budget: inout Int) -> AXUIElement? {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(
            element, ["AXDOMClassList", kAXChildrenAttribute] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let values = (raw as? [Any]) ?? []
        if (values.first as? [String])?.contains(domClass) == true { return element }
        guard values.count > 1, let children = values[1] as? [AXUIElement] else { return nil }
        for child in children where budget > 0 {
            if let hit = find(domClass: domClass, in: child, budget: &budget) { return hit }
        }
        return nil
    }

    private static func find(domID: String, in element: AXUIElement, budget: inout Int) -> AXUIElement? {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(
            element, ["AXDOMIdentifier", kAXChildrenAttribute] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let values = (raw as? [Any]) ?? []
        if values.first as? String == domID { return element }
        guard values.count > 1, let children = values[1] as? [AXUIElement] else { return nil }
        for child in children where budget > 0 {
            if let hit = find(domID: domID, in: child, budget: &budget) { return hit }
        }
        return nil
    }

    private static func hasWebContent(_ windows: [Node]) -> Bool {
        windows.contains { window in
            window.first { $0.role == "AXWebArea" && !$0.children.isEmpty } != nil
        }
    }

    private static func readWindows(of app: AXUIElement, bundleID: String, focusedWindowOnly: Bool,
                                    includeWebSemantics: Bool) throws -> [Node] {
        var value: CFTypeRef?
        if focusedWindowOnly {
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw ReaderError.noFocusedWindow(bundleID: bundleID)
            }
            var budget = maxNodes
            return [read(value as! AXUIElement, budget: &budget, includeWebSemantics: includeWebSemantics)]
        }
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard let windows = value as? [AXUIElement], !windows.isEmpty else {
            throw ReaderError.noWindows(bundleID: bundleID)
        }
        var budget = maxNodes
        return windows.map { read($0, budget: &budget, includeWebSemantics: includeWebSemantics) }
    }

    private static func read(_ element: AXUIElement, budget: inout Int, includeWebSemantics: Bool) -> Node {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(
            element, (attributes + (includeWebSemantics ? webAttributes : [])) as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        // One call for all attributes: each accessibility call is a round trip to the app, and a
        // tree has hundreds to thousands of nodes.
        // A missing attribute comes back as an error placeholder, which fails the casts below.
        let values = (raw as? [Any]) ?? []
        func string(_ index: Int) -> String? {
            guard index < values.count, let text = values[index] as? String, !text.isEmpty else { return nil }
            return text
        }
        var node = Node(
            role: string(0) ?? "AXUnknown",
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
            func headers(_ index: Int) -> [String]? {
                guard index < values.count, let elements = values[index] as? [AXUIElement], !elements.isEmpty else { return nil }
                return elements.map { headerText($0, depth: 0) }.filter { !$0.isEmpty }
            }
            var web = WebAttributes()
            if values.count > 9 { web.url = (values[9] as? URL)?.absoluteString ?? string(9) }
            web.valueDescription = string(10)
            web.placeholder = string(11)
            web.enabled = bool(12)
            web.selected = bool(13)
            // Chromium can return false for AXExpanded even on elements that do not expose it.
            if bool(14) != nil {
                var supported: CFArray?
                AXUIElementCopyAttributeNames(element, &supported)
                if (supported as? [String])?.contains("AXExpanded") == true { web.expanded = bool(14) }
            }
            web.required = bool(15)
            let row = range(16), column = range(17)
            web.rowIndex = row?.location
            web.rowSpan = row?.length
            web.columnIndex = column?.location
            web.columnSpan = column?.length
            web.columnHeaders = headers(18)
            web.rowHeaders = headers(19)
            node.web = web
        }
        if values.count > 8, CFGetTypeID(values[8] as CFTypeRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(values[8] as! AXValue, .cgRect, &rect) { node.frame = rect }
        }
        if values.count > 7, let children = values[7] as? [AXUIElement] {
            for child in children where budget > 0 {
                node.children.append(read(child, budget: &budget, includeWebSemantics: includeWebSemantics))
            }
        }
        return node
    }

    private static func headerText(_ element: AXUIElement, depth: Int) -> String {
        guard depth < 8 else { return "" }
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, ["AXTitle", "AXValue", "AXDescription", "AXChildren"] as CFArray,
                                               AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let values = raw as? [Any] ?? []
        for value in values.prefix(3) {
            if let text = value as? String, !text.isEmpty { return text }
        }
        guard values.count > 3, let children = values[3] as? [AXUIElement] else { return "" }
        return children.prefix(100).map { headerText($0, depth: depth + 1) }.joined()
    }
}
