/// Optional web semantics. Older snapshots remain readable without these attributes.
public struct WebAttributes: Codable, Equatable, Sendable {
    public var url: String?
    public var valueDescription: String?
    public var placeholder: String?
    public var enabled: Bool?
    public var selected: Bool?
    public var expanded: Bool?
    public var required: Bool?
    public var rowIndex: Int?
    public var rowSpan: Int?
    public var columnIndex: Int?
    public var columnSpan: Int?
    public var columnHeaders: [String]?
    public var rowHeaders: [String]?

    public init() {}
}
