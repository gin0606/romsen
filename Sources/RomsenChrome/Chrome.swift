import ArgumentParser
import AXSnapshot
import AXTree
import Foundation

public struct Chrome: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        abstract: "Print the main content of the page open in Google Chrome's focused window.",
        discussion: """
            Reads the selected tab through the macOS Accessibility API, without scrolling, \
            switching tabs or bringing Chrome forward. Prints the page title, URL and structured \
            text: headings, paragraphs, links, lists, tables and labelled controls with their state. \
            By default, reads declared main regions and open dialogs. Supplementary content inside \
            main regions is retained. If no main region is declared, omits recognised navigation, \
            sidebars, banners, footers and search regions while keeping other content. --all reads \
            the whole page. Browser toolbars are excluded. Text outside the viewport may be included; content not \
            exposed to accessibility cannot be read. Layout and unlabelled regions cannot always \
            be reconstructed. Saved trees only provide the attributes captured when saved.

            Example: romsen chrome
                     romsen chrome --all
                     romsen chrome --save-snapshot /tmp/page.json
                     romsen chrome --from-snapshot /tmp/page.json
            """
    )

    @Flag(help: "Print the unprocessed accessibility tree of the focused window.")
    var raw = false

    @Flag(help: "Read the whole page, including navigation and sidebars. --raw always includes the whole window.")
    var all = false

    @Option(help: "Save the focused window as JSON. Contains page content; keep it private.")
    var saveSnapshot: String?

    @Option(help: "Read a saved JSON tree instead of Chrome. No Accessibility permission needed.")
    var fromSnapshot: String?

    func read(using snapshot: () throws -> [Node]) throws -> String {
        let windows: [Node]
        if let fromSnapshot {
            do {
                windows = try JSONDecoder().decode([Node].self, from: Data(contentsOf: URL(fileURLWithPath: fromSnapshot)))
            } catch {
                throw ValidationError("could not read snapshot at \(fromSnapshot): \(error.localizedDescription)")
            }
        } else {
            windows = try snapshot()
        }
        if let saveSnapshot {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(windows).write(to: URL(fileURLWithPath: saveSnapshot), options: .atomic)
            } catch {
                throw ValidationError("could not save snapshot at \(saveSnapshot): \(error.localizedDescription)")
            }
        }
        if raw { return windows.map { $0.outline() }.joined(separator: "\n") }
        guard windows.count == 1 else {
            throw ValidationError("Could not identify a page in Chrome's focused window. Select a loaded tab and try again.")
        }
        let pages = windows[0].all { $0.role == "AXWebArea" }
        guard pages.count == 1, let page = pages.first else {
            throw ValidationError("Could not identify a single page in Chrome's focused window. Select a loaded tab or use --raw to inspect the window.")
        }
        return ChromeRenderer.render(all ? page : ChromeContent.main(page))
    }

    public func run() throws {
        do {
            print(try read {
                try Reader.snapshotWindows(bundleID: "com.google.Chrome", focusedWindowOnly: true, includeWebSemantics: true)
            })
        } catch let error as ReaderError {
            FileHandle.standardError.write(Data("romsen: \(error.description)\n".utf8))
            throw ExitCode.failure
        }
    }
}
