//
//  JSONNodeSerializer.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation

/// Writes a `JSONNode` back out, preserving entry order and number literals.
public enum JSONNodeSerializer {

    public enum Format: Sendable {
        case compact
        /// Two-space indent, one entry per line. Used by the detail view.
        case pretty
    }

    public static func string(from node: JSONNode, format: Format = .compact) -> String {
        var output = ""
        write(node, into: &output, format: format, depth: 0)
        return output
    }

    public static func data(from node: JSONNode, format: Format = .compact) -> Data {
        Data(string(from: node, format: format).utf8)
    }

    private static func write(_ node: JSONNode, into output: inout String, format: Format, depth: Int) {
        switch node {
        case .object(let entries):
            guard !entries.isEmpty else { output += "{}"; return }
            output += "{"
            for (index, entry) in entries.enumerated() {
                if index > 0 { output += "," }
                newline(&output, format: format, depth: depth + 1)
                writeString(entry.key, into: &output)
                output += format == .pretty ? ": " : ":"
                write(entry.value, into: &output, format: format, depth: depth + 1)
            }
            newline(&output, format: format, depth: depth)
            output += "}"

        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                newline(&output, format: format, depth: depth + 1)
                write(item, into: &output, format: format, depth: depth + 1)
            }
            newline(&output, format: format, depth: depth)
            output += "]"

        case .string(let value):
            writeString(value, into: &output)

        case .number(let literal):
            // Verbatim. Never reformatted — this is the whole point.
            output += literal

        case .bool(let value):
            output += value ? "true" : "false"

        case .null:
            output += "null"
        }
    }

    private static func newline(_ output: inout String, format: Format, depth: Int) {
        guard format == .pretty else { return }
        output += "\n"
        output += String(repeating: "  ", count: depth)
    }

    /// Escapes only what RFC 8259 requires, so output is stable under repeated
    /// round-trips even though it does not reproduce the input's choice of
    /// escape spelling (`A` is parsed to `A` and written back as `A`).
    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case UnicodeScalar(0x08): output += "\\b"
            case UnicodeScalar(0x0C): output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
