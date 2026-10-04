import AXTree
import Foundation
import Testing

private func chromeWindow(_ children: [Node]) -> [Node] {
    [Node(role: "AXWindow", title: "Browser window", children: [
        Node(role: "AXToolbar", children: [Node(role: "AXButton", title: "Browser toolbar")]),
        Node(role: "AXTabGroup", children: [Node(role: "AXRadioButton", title: "Background tab")]),
        Node(role: "AXGroup", children: [Node(role: "AXWebArea", title: "Example page", children: children)])
    ])]
}

private final class ChromeTestBundle: NSObject {}

@Test func chromeCLIReportsOutputAndErrorsOnSeparateStreams() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("page.json")
    let products = Bundle(for: ChromeTestBundle.self).bundleURL.deletingLastPathComponent()
    for hasPage in [true, false] {
        let windows = hasPage ? chromeWindow([Node(role: "AXStaticText", value: "Page body")]) : []
        try JSONEncoder().encode(windows).write(to: file)
        let process = Process()
        process.executableURL = products.appendingPathComponent("romsen")
        process.arguments = ["chrome", "--from-snapshot", file.path]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if hasPage {
            #expect(stdout == "# Example page\n\nPage body\n")
            #expect(stderr.isEmpty)
            #expect(process.terminationStatus == 0)
        } else {
            #expect(stdout.isEmpty)
            #expect(stderr.contains("Could not identify a page"))
            #expect(process.terminationStatus != 0)
        }
    }
}
