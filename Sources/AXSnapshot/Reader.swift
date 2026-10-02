import AppKit
import ApplicationServices

public enum ReaderError: Error, CustomStringConvertible {
    case notTrusted
    case notRunning(bundleID: String)
    case noWindows(bundleID: String)

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

    /// Chromium-based apps build their accessibility tree only once an assistive client asks for
    /// it, so this sets `AXManualAccessibility` on the app and waits for the web content to
    /// appear. The switch stays on afterwards, which keeps later reads fast.
    ///
    /// Measured on Slack: before the switch the window holds only native chrome and an empty
    /// web area; about three seconds after it, the full tree is there. With the switch already
    /// on, a read takes well under a second. The switch resets when the app restarts.
    public static func snapshotWindows(bundleID: String, webContentTimeout: TimeInterval = 10) throws -> [Node] {
        guard AXIsProcessTrusted() else { throw ReaderError.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw ReaderError.notRunning(bundleID: bundleID)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 5)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var windows = try readWindows(of: element, bundleID: bundleID)
        // The web content fills in over a few seconds, so wait until two reads in a row agree.
        let deadline = Date().addingTimeInterval(webContentTimeout)
        var previousCount = -1
        while Date() < deadline {
            let count = windows.reduce(0) { $0 + $1.nodeCount }
            if hasWebContent(windows), count == previousCount { break }
            previousCount = count
            Thread.sleep(forTimeInterval: 0.3)
            windows = try readWindows(of: element, bundleID: bundleID)
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

    private static func readWindows(of app: AXUIElement, bundleID: String) throws -> [Node] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard let windows = value as? [AXUIElement], !windows.isEmpty else {
            throw ReaderError.noWindows(bundleID: bundleID)
        }
        var budget = maxNodes
        return windows.map { read($0, budget: &budget) }
    }

    private static func read(_ element: AXUIElement, budget: inout Int) -> Node {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
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
        if values.count > 8, CFGetTypeID(values[8] as CFTypeRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(values[8] as! AXValue, .cgRect, &rect) { node.frame = rect }
        }
        if values.count > 7, let children = values[7] as? [AXUIElement] {
            for child in children where budget > 0 {
                node.children.append(read(child, budget: &budget))
            }
        }
        return node
    }
}
