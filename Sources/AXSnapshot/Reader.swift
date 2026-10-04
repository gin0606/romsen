import AXTree
import AppKit
import ApplicationServices

public enum ReaderError: Error, CustomStringConvertible, Equatable {
    case notTrusted
    case notRunning(bundleID: String)
    case noWindows(bundleID: String)
    case noFocusedWindow(bundleID: String)
    case acquisitionFailed(operation: String, code: Int32)
    case invalidAttribute(String)
    case nodeLimitExceeded
    case depthLimitExceeded
    case webContentTimedOut

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
            "\(bundleID) has no focused window to read. Select a window and try again."
        case let .acquisitionFailed(operation, code):
            "Accessibility operation \(operation) failed (error \(code))."
        case let .invalidAttribute(name):
            "Accessibility returned an invalid or missing \(name) attribute."
        case .nodeLimitExceeded:
            "Accessibility snapshot exceeded the node limit; incomplete content was not returned."
        case .depthLimitExceeded:
            "Accessibility snapshot exceeded the depth limit; incomplete content was not returned."
        case .webContentTimedOut:
            "Accessibility web content did not become ready before the timeout."
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
    private static let maxNodes = 50_000

    public enum Preparation {
        case none
        /// Enable Chromium's accessibility tree, then wait for stable web content.
        case chromium(timeout: TimeInterval = 10)
    }

    public static func snapshotWindows(
        bundleID: String, focusedWindowOnly: Bool = false, includeWebSemantics: Bool = false,
        preparation: Preparation = .none
    ) throws -> [Node] {
        guard AXIsProcessTrusted() else { throw ReaderError.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw ReaderError.notRunning(bundleID: bundleID)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        try AXAccess.check(AXUIElementSetMessagingTimeout(element, 5), operation: "set messaging timeout")
        return try preparedSnapshot(preparation, prepare: {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }, snapshot: {
            try readWindows(of: element, bundleID: bundleID, focusedWindowOnly: focusedWindowOnly,
                            includeWebSemantics: includeWebSemantics)
        })
    }

    static func preparedSnapshot(
        _ preparation: Preparation, prepare: () throws -> AXError, snapshot: () throws -> [Node],
        now: () -> Date = { Date() }, pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> [Node] {
        guard case let .chromium(timeout) = preparation else { return try snapshot() }
        // Chrome can expose its tree without supporting Electron's manual-accessibility switch.
        let status = try prepare()
        if status != .attributeUnsupported {
            try AXAccess.check(status, operation: "enable AXManualAccessibility")
        }
        let deadline = now().addingTimeInterval(timeout)
        var windows = try snapshot()
        while now() < deadline {
            let previous = windows.reduce(0) { $0 + $1.nodeCount }
            pause(min(0.3, max(0, deadline.timeIntervalSince(now()))))
            windows = try snapshot()
            if windows.contains(where: { $0.first { $0.role == "AXWebArea" && !$0.children.isEmpty } != nil }),
               windows.reduce(0, { $0 + $1.nodeCount }) == previous { return windows }
        }
        throw ReaderError.webContentTimedOut
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

    private static func readWindows(of app: AXUIElement, bundleID: String, focusedWindowOnly: Bool,
                                    includeWebSemantics: Bool) throws -> [Node] {
        let windows: [AXUIElement]
        if focusedWindowOnly {
            guard let value = try AXAccess.attribute(app, kAXFocusedWindowAttribute) else {
                throw ReaderError.noFocusedWindow(bundleID: bundleID)
            }
            guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else {
                throw ReaderError.invalidAttribute(kAXFocusedWindowAttribute)
            }
            windows = [value as! AXUIElement]
        } else {
            let value = try AXAccess.attribute(app, kAXWindowsAttribute)
            if value == nil { throw ReaderError.noWindows(bundleID: bundleID) }
            guard let elements = value as? [AXUIElement] else {
                throw ReaderError.invalidAttribute(kAXWindowsAttribute)
            }
            guard !elements.isEmpty else { throw ReaderError.noWindows(bundleID: bundleID) }
            windows = elements
        }
        var capture = SnapshotCapture<AXUIElement>(includeWebSemantics: includeWebSemantics,
                                                  values: AXAccess.values, names: AXAccess.names)
        return try capture.windows(windows)
    }
}
