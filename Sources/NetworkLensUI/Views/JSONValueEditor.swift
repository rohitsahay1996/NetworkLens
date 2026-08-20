//
//  JSONValueEditor.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 20/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Edits one leaf of a payload, typed to what the leaf actually is.
///
/// The alternative — and what this replaces — is retyping the surrounding JSON
/// in a `TextEditor`. That is the most common operation in the tool and was the
/// worst thing in it: a phone keyboard, no structure, and a payload that stops
/// parsing the moment a quote goes missing.
struct JSONValueEditor: View {

    let pointer: JSONPointer
    let label: String?
    let node: JSONNode
    let commit: (JSONNode) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind
    @State private var text: String
    @State private var flag: Bool

    /// The leaf kinds worth offering. Turning a scalar into an object or an
    /// array is a structural change, not a value edit — that belongs to the
    /// row's own actions, where the consequences are visible.
    enum Kind: String, CaseIterable, Identifiable {
        case string, number, boolean, null
        var id: String { rawValue }
        var label: String {
            switch self {
            case .string: return "Text"
            case .number: return "Number"
            case .boolean: return "True/false"
            case .null: return "Null"
            }
        }
    }

    init(
        pointer: JSONPointer,
        label: String?,
        node: JSONNode,
        commit: @escaping (JSONNode) -> Void
    ) {
        self.pointer = pointer
        self.label = label
        self.node = node
        self.commit = commit

        switch node {
        case .string(let value):
            _kind = State(initialValue: .string)
            _text = State(initialValue: value)
            _flag = State(initialValue: false)
        case .number(let literal):
            _kind = State(initialValue: .number)
            // The literal, not a `Double`. Round-tripping a long id through a
            // binary float is how "9007199254740993" becomes "9007199254740992".
            _text = State(initialValue: literal)
            _flag = State(initialValue: false)
        case .bool(let value):
            _kind = State(initialValue: .boolean)
            _text = State(initialValue: "")
            _flag = State(initialValue: value)
        default:
            _kind = State(initialValue: .null)
            _text = State(initialValue: "")
            _flag = State(initialValue: false)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    LabelledRow(
                        label: "Field",
                        value: label ?? "root",
                        monospaced: true
                    )
                    LabelledRow(label: "Path", value: pointer.description, monospaced: true)
                }

                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch kind {
                    case .string:
                        // A plain field, not a growing one: `TextField(axis:)`
                        // and range `lineLimit` are both iOS 16, and this
                        // package supports 15.
                        TextField("Value", text: $text)
                            .font(.system(.body, design: .monospaced))
                    case .number:
                        TextField("Value", text: $text)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numbersAndPunctuation)
                    case .boolean:
                        Toggle("Value", isOn: $flag)
                    case .null:
                        Text("null")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if kind == .number, !isValidNumber {
                        Text("Not a JSON number. Save is disabled rather than quietly writing this as text — a quoted number is a different payload, and the app's decoder will say so.")
                            .foregroundStyle(.orange)
                    } else if kind == .number {
                        Text("Kept as the literal you type, so long ids and trailing zeros survive exactly.")
                    }
                }
            }
            .navigationTitle("Edit value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        commit(edited)
                        dismiss()
                    }
                    .disabled(kind == .number && !isValidNumber)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var edited: JSONNode {
        switch kind {
        case .string:  return .string(text)
        case .number:  return .number(text.trimmingCharacters(in: .whitespaces))
        case .boolean: return .bool(flag)
        case .null:    return .null
        }
    }

    /// Validated by the real parser rather than by a regex, so what is accepted
    /// here is exactly what the payload will accept.
    private var isValidNumber: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let parsed = try? JSONNodeParser.parse(trimmed), case .number = parsed else {
            return false
        }
        return true
    }
}
#endif
