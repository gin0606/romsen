import Foundation

/// A link to one Slack message: `https://<workspace>.slack.com/archives/<channel>/p<timestamp digits>`.
package struct SlackLink: Equatable, Sendable {
    package var channelID: String
    /// Slack's message timestamp, such as `1700000000.000100`.
    package var timestamp: String
    /// The timestamp of the thread's first message, when the link points into a thread.
    package var threadTimestamp: String?

    package init?(_ text: String) {
        guard let url = URL(string: text), url.host?.hasSuffix(".slack.com") == true else { return nil }
        let parts = url.pathComponents
        guard parts.count == 4, parts[1] == "archives", parts[3].hasPrefix("p") else { return nil }
        let digits = parts[3].dropFirst()
        // The link drops the dot that precedes the six microsecond digits.
        guard digits.count > 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        channelID = parts[2]
        timestamp = "\(digits.dropLast(6)).\(digits.suffix(6))"
        threadTimestamp = URLComponents(string: text)?.queryItems?.first { $0.name == "thread_ts" }?.value
    }
}
