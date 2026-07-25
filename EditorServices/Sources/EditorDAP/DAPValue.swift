import Foundation

public enum DAPValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([DAPValue])
    case object([String: DAPValue])

    public static func encode<T: Encodable & Sendable>(_ value: T, using encoder: JSONEncoder = JSONEncoder()) throws -> DAPValue {
        try JSONDecoder().decode(DAPValue.self, from: encoder.encode(value))
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension DAPValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([DAPValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: DAPValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension DAPValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension DAPValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension DAPValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int64) { self = .integer(value) } }
extension DAPValue: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .number(value) } }
extension DAPValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension DAPValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: DAPValue...) { self = .array(elements) } }
extension DAPValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, DAPValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new })) }
}
