import ApplicationServices
import Foundation

/// Preserves acquisition failures while treating unsupported optional attributes as absent.
enum AXAccess {
    static func check(_ status: AXError, operation: String) throws {
        guard status == .success else {
            throw ReaderError.acquisitionFailed(operation: operation, code: status.rawValue)
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) throws -> Any? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return try attributeResult(status, value: value, name: name)
    }

    static func attributeResult(_ status: AXError, value: Any?, name: String) throws -> Any? {
        if status == .noValue { return nil }
        try check(status, operation: name)
        guard let value else { throw ReaderError.invalidAttribute(name) }
        return value
    }

    static func values(_ element: AXUIElement, _ attributes: [String]) throws -> [Any?] {
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        return try attributeResults(status, values: raw as? [Any], names: attributes)
    }

    static func attributeResults(_ status: AXError, values: [Any]?, names: [String]) throws -> [Any?] {
        try check(status, operation: "read attributes")
        guard let values, values.count == names.count else { throw ReaderError.invalidAttribute("attribute results") }
        return try zip(names, values).map { name, value in
            guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
                  AXValueGetType(value as! AXValue) == .axError else { return value }
            var error = AXError.failure
            guard AXValueGetValue(value as! AXValue, .axError, &error) else {
                throw ReaderError.invalidAttribute(name)
            }
            if error == .attributeUnsupported || error == .noValue { return nil }
            try check(error, operation: name)
            throw ReaderError.invalidAttribute(name)
        }
    }

    static func names(_ element: AXUIElement) throws -> [String] {
        var raw: CFArray?
        try check(AXUIElementCopyAttributeNames(element, &raw), operation: "read attribute names")
        guard let names = raw as? [String] else { throw ReaderError.invalidAttribute("attribute names") }
        return names
    }
}
