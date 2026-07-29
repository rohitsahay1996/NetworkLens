import Foundation

/// A hand-written recursive descent JSON parser.
///
/// Exists because the goal is fidelity, not speed: object key order, duplicate
/// keys and number literals all survive. Operates on UTF-8 bytes.
public enum JSONNodeParser {

    public struct Error: Swift.Error, CustomStringConvertible, Sendable {
        public let message: String
        public let byteOffset: Int

        public var description: String { "\(message) at byte \(byteOffset)" }
    }

    public static func parse(_ data: Data) throws -> JSONNode {
        var scanner = Scanner(bytes: Array(data))
        scanner.skipWhitespace()
        let node = try scanner.parseValue()
        scanner.skipWhitespace()
        guard scanner.isAtEnd else {
            throw Error(message: "Unexpected trailing bytes", byteOffset: scanner.offset)
        }
        return node
    }

    public static func parse(_ string: String) throws -> JSONNode {
        try parse(Data(string.utf8))
    }
}

// MARK: - Scanner

extension JSONNodeParser {

    fileprivate struct Scanner {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { offset >= bytes.count }

        private var current: UInt8? { isAtEnd ? nil : bytes[offset] }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                offset += 1
            }
        }

        mutating func parseValue() throws -> JSONNode {
            guard let byte = current else {
                throw Error(message: "Unexpected end of input", byteOffset: offset)
            }
            switch byte {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumberLiteral())
            }
        }

        private mutating func parseObject() throws -> JSONNode {
            offset += 1 // {
            var entries: [JSONNode.Entry] = []
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                offset += 1
                return .object(entries)
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else {
                    throw Error(message: "Expected object key", byteOffset: offset)
                }
                let key = try parseString()
                skipWhitespace()
                guard current == UInt8(ascii: ":") else {
                    throw Error(message: "Expected ':'", byteOffset: offset)
                }
                offset += 1
                skipWhitespace()
                entries.append(JSONNode.Entry(key: key, value: try parseValue()))
                skipWhitespace()
                switch current {
                case UInt8(ascii: ","):
                    offset += 1
                case UInt8(ascii: "}"):
                    offset += 1
                    return .object(entries)
                default:
                    throw Error(message: "Expected ',' or '}'", byteOffset: offset)
                }
            }
        }

        private mutating func parseArray() throws -> JSONNode {
            offset += 1 // [
            var items: [JSONNode] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                offset += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                switch current {
                case UInt8(ascii: ","):
                    offset += 1
                case UInt8(ascii: "]"):
                    offset += 1
                    return .array(items)
                default:
                    throw Error(message: "Expected ',' or ']'", byteOffset: offset)
                }
            }
        }

        /// Decodes escapes into their real characters. `😀` becomes a
        /// single emoji scalar; the serializer re-escapes only what JSON
        /// requires, which makes round-tripping idempotent rather than
        /// byte-identical for escape *spelling*.
        private mutating func parseString() throws -> String {
            offset += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            while true {
                guard let byte = current else {
                    throw Error(message: "Unterminated string", byteOffset: offset)
                }
                if byte == UInt8(ascii: "\"") {
                    offset += 1
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    offset += 1
                    guard let escape = current else {
                        throw Error(message: "Unterminated escape", byteOffset: offset)
                    }
                    offset += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append(UnicodeScalar(0x08)!)
                    case UInt8(ascii: "f"): scalars.append(UnicodeScalar(0x0C)!)
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"): scalars.append(try parseUnicodeEscape())
                    default:
                        throw Error(message: "Invalid escape", byteOffset: offset - 1)
                    }
                    continue
                }
                // Raw UTF-8 byte run up to the next quote or backslash.
                let start = offset
                while let byte = current,
                      byte != UInt8(ascii: "\""), byte != UInt8(ascii: "\\") {
                    offset += 1
                }
                guard let chunk = String(bytes: bytes[start..<offset], encoding: .utf8) else {
                    throw Error(message: "Invalid UTF-8 in string", byteOffset: start)
                }
                scalars.append(contentsOf: chunk.unicodeScalars)
            }
        }

        /// Reads the four hex digits after `\u`, pairing surrogates.
        private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
            let value = try parseHexQuad()
            guard (0xD800...0xDBFF).contains(value) else {
                guard let scalar = UnicodeScalar(value) else {
                    throw Error(message: "Invalid unicode escape", byteOffset: offset)
                }
                return scalar
            }
            // High surrogate — a low surrogate must follow.
            guard current == UInt8(ascii: "\\"), offset + 1 < bytes.count,
                  bytes[offset + 1] == UInt8(ascii: "u") else {
                throw Error(message: "Unpaired high surrogate", byteOffset: offset)
            }
            offset += 2
            let low = try parseHexQuad()
            guard (0xDC00...0xDFFF).contains(low) else {
                throw Error(message: "Invalid low surrogate", byteOffset: offset)
            }
            let combined = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = UnicodeScalar(combined) else {
                throw Error(message: "Invalid surrogate pair", byteOffset: offset)
            }
            return scalar
        }

        private mutating func parseHexQuad() throws -> UInt32 {
            guard offset + 4 <= bytes.count else {
                throw Error(message: "Truncated unicode escape", byteOffset: offset)
            }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[offset]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
                default:
                    throw Error(message: "Invalid hex digit in unicode escape", byteOffset: offset)
                }
                value = value << 4 | digit
                offset += 1
            }
            return value
        }

        /// Captures the number's source text verbatim after validating its shape.
        private mutating func parseNumberLiteral() throws -> String {
            let start = offset
            if current == UInt8(ascii: "-") { offset += 1 }

            let integerDigits = consumeDigits()
            guard integerDigits > 0 else {
                throw Error(message: "Invalid number", byteOffset: start)
            }
            if current == UInt8(ascii: ".") {
                offset += 1
                guard consumeDigits() > 0 else {
                    throw Error(message: "Expected digits after '.'", byteOffset: offset)
                }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                offset += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { offset += 1 }
                guard consumeDigits() > 0 else {
                    throw Error(message: "Expected digits in exponent", byteOffset: offset)
                }
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }

        private mutating func consumeDigits() -> Int {
            var count = 0
            while let byte = current, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                offset += 1
                count += 1
            }
            return count
        }

        private mutating func expect(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard offset + expected.count <= bytes.count,
                  Array(bytes[offset..<(offset + expected.count)]) == expected else {
                throw Error(message: "Expected '\(literal)'", byteOffset: offset)
            }
            offset += expected.count
        }
    }
}
