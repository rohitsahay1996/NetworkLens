//
//  BodyRenderer.swift
//  NetworkLensUI
//
//  Created by Rohit Sahay on 20/08/26.
//

#if canImport(UIKit)
import SwiftUI
import NetworkLensCore

/// Everything the body views need to draw a payload, derived once and off the
/// main thread.
///
/// The views used to derive all of it inside `body`: classification parsed the
/// payload to find out whether it was JSON, the tree parsed it a second time,
/// and the raw view parsed and re-serialised it a third. SwiftUI re-evaluates
/// `body` on every store notification, so on a screen that is still making
/// requests a megabyte response was reparsed several times *per captured
/// request* — which is the entire main thread for as long as traffic arrives.
struct RenderedBody: Sendable {

    /// One display line.
    ///
    /// Split up front because a single `Text` holding a megabyte lays the whole
    /// string out synchronously before the first frame can be drawn, and there
    /// is no way to ask it not to. Lines let the view draw a page at a time.
    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String
    }

    enum Kind: Sendable {
        case empty
        case json(JSONTree)
        case text
        /// Byte count and a short hex preview. There is nothing to lay out.
        case binary(byteCount: Int, hexPreview: String)
    }

    var kind: Kind
    /// Pretty-printed JSON, or the payload as text. Empty for binary bodies.
    var lines: [Line]

    static let empty = RenderedBody(kind: .empty, lines: [])

    // MARK: - Building

    /// Classifies and lays out a body. Never throws: an unparseable payload is
    /// a normal outcome here, because the capture cap cuts bodies mid-token.
    static func make(data: Data?, contentType: String?) -> RenderedBody {
        guard let data, !data.isEmpty else { return .empty }

        // One parse, reused for the classification, the tree and the raw text.
        if let node = try? JSONNodeParser.parse(data) {
            return RenderedBody(
                kind: .json(JSONTree(node: node)),
                lines: split(JSONNodeSerializer.string(from: node, format: .pretty))
            )
        }

        // Not JSON, so the parse inside `bodyPresentation` fails on the first
        // byte rather than walking the payload — cheap enough to call here.
        switch data.bodyPresentation(contentType: contentType) {
        case .empty:
            return .empty
        case .text(let text):
            return RenderedBody(kind: .text, lines: split(text))
        case .binary(let byteCount, let hexPreview):
            return RenderedBody(
                kind: .binary(byteCount: byteCount, hexPreview: hexPreview),
                lines: []
            )
        case .json:
            // Unreachable: the parse above just failed on these same bytes.
            // Falling through to text rather than trapping, because showing the
            // capture is more useful than insisting it cannot exist.
            return RenderedBody(
                kind: .text,
                lines: split(String(decoding: data, as: UTF8.self))
            )
        }
    }

    private static func split(_ text: String) -> [Line] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { Line(id: $0.offset, text: String($0.element)) }
    }
}

// MARK: - Tree

/// A parsed payload flattened into the rows the tree draws, plus the collapse
/// state those rows were flattened against.
///
/// Both halves are built here rather than in the view: seeding the collapse
/// walks every node in the payload, and the first flatten walks everything
/// still expanded. On a large body that is tens of milliseconds each, and
/// `onAppear` runs them on the main thread.
struct JSONTree: Sendable {

    let node: JSONNode
    /// Collapsed containers, by path. Collapsed is the exception, so a small
    /// payload needs no interaction — but see `initiallyCollapsed`.
    let collapsed: Set<String>
    /// Only what is visible under `collapsed`.
    let rows: [JSONTreeRow.Row]

    init(node: JSONNode) {
        self.node = node
        let collapsed = Self.initiallyCollapsed(node)
        self.collapsed = collapsed
        var rows: [JSONTreeRow.Row] = []
        Self.flatten(node, label: nil, path: "", depth: 0, collapsed: collapsed, into: &rows)
        self.rows = rows
    }

    // MARK: - Flattening

    /// Walks only what is visible. A collapsed container contributes its own
    /// row and nothing beneath it, which is what keeps a 10k-node payload
    /// affordable to draw.
    static func flatten(
        _ node: JSONNode,
        label: String?,
        path: String,
        depth: Int,
        collapsed: Set<String>,
        into output: inout [JSONTreeRow.Row]
    ) {
        output.append(JSONTreeRow.Row(path: path, label: label, node: node, depth: depth))
        guard node.isContainer, !collapsed.contains(path) else { return }
        flattenChildren(of: node, path: path, depth: depth, collapsed: collapsed, into: &output)
    }

    /// The rows a container contributes below itself, without the container's
    /// own row. This is what an expand inserts, so expanding costs the subtree
    /// rather than the whole payload.
    static func flattenChildren(
        of node: JSONNode,
        path: String,
        depth: Int,
        collapsed: Set<String>,
        into output: inout [JSONTreeRow.Row]
    ) {
        switch node {
        case .object(let entries):
            for entry in entries {
                flatten(
                    entry.value, label: entry.key, path: "\(path)/\(entry.key)",
                    depth: depth + 1, collapsed: collapsed, into: &output
                )
            }
        case .array(let elements):
            for (index, element) in elements.enumerated() {
                flatten(
                    element, label: "\(index)", path: "\(path)/\(index)",
                    depth: depth + 1, collapsed: collapsed, into: &output
                )
            }
        default:
            break
        }
    }

    /// The paths of a container's *immediate* child containers.
    ///
    /// Expanding reveals one level at a time, so the children a tap uncovers
    /// have to be marked collapsed as they are uncovered. Doing it here, per
    /// tap, is what lets `initiallyCollapsed` stop at the first collapsed
    /// container instead of walking every node in the payload to record paths
    /// no row will ever ask about.
    static func childContainerPaths(of node: JSONNode, path: String) -> Set<String> {
        var output: Set<String> = []
        switch node {
        case .object(let entries):
            for entry in entries where entry.value.isContainer {
                output.insert("\(path)/\(entry.key)")
            }
        case .array(let elements):
            for (index, element) in elements.enumerated() where element.isContainer {
                output.insert("\(path)/\(index)")
            }
        default:
            break
        }
        return output
    }

    /// Collapses containers below the second level on first show.
    ///
    /// The top two levels are the shape of the payload and are what someone
    /// opening a body is looking for; everything under them is detail they can
    /// ask for. Without this a large response opens as a wall of rows, which is
    /// the problem the tree was supposed to solve.
    static func initiallyCollapsed(_ node: JSONNode, maxExpandedDepth: Int = 2) -> Set<String> {
        var output: Set<String> = []
        func walk(_ node: JSONNode, path: String, depth: Int) {
            guard node.isContainer else { return }
            if depth >= maxExpandedDepth {
                output.insert(path)
                // Nothing under a collapsed container is ever drawn until it is
                // expanded, and expanding re-derives its children's state from
                // the same rule. Walking on would visit every node in the
                // payload to record paths no row will ask about.
                return
            }
            switch node {
            case .object(let entries):
                for entry in entries {
                    walk(entry.value, path: "\(path)/\(entry.key)", depth: depth + 1)
                }
            case .array(let elements):
                for (index, element) in elements.enumerated() {
                    walk(element, path: "\(path)/\(index)", depth: depth + 1)
                }
            default:
                break
            }
        }
        walk(node, path: "", depth: 0)
        return output
    }
}

// MARK: - Editor support

/// Debounced, off-main answer to "is this buffer JSON".
///
/// Both editors used to answer it by parsing their buffer inside `body`. The
/// breakpoint sheet redraws twice a second on its auto-resume countdown, so a
/// held megabyte payload was fully reparsed twice a second — while the app was
/// stopped and the tester was trying to type into it.
@MainActor
final class JSONValidity: ObservableObject {

    /// Starts true so an editor opening on a valid payload does not flash the
    /// "not JSON" footer before the first check lands.
    @Published private(set) var isValid = true

    private var task: Task<Void, Never>?

    func check(_ text: String) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let valid = await Task.detached(priority: .utility) {
                (try? JSONNodeParser.parse(Data(text.utf8))) != nil
            }.value
            guard !Task.isCancelled else { return }
            self?.isValid = valid
        }
    }
}

/// Pretty-printed body text, cached by payload.
///
/// The mock editor derives this in `init` — which SwiftUI runs on every
/// evaluation of the *presenting* view's `body`, not once per presentation —
/// and again in `isEdited` on every evaluation of its own. Parsing and
/// re-serialising a megabyte in either place is a dropped frame each time, and
/// the answer is the same every time.
enum BodyText {

    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 8
        return cache
    }()

    /// Reformatted through the ordered serializer, so key order and number
    /// literals survive — a pretty-printer that reorders keys makes a diff
    /// against the server's response useless. Raw text for anything not JSON.
    static func pretty(from data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        let key = BodyFingerprint(data: data, contentType: nil).cacheKey
        if let hit = cache.object(forKey: key) { return hit as String }

        let text: String
        if let node = try? JSONNodeParser.parse(data) {
            text = JSONNodeSerializer.string(from: node, format: .pretty)
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }
        cache.setObject(text as NSString, forKey: key)
        return text
    }
}

/// Past this, a body is not handed to a `TextEditor` unless the tester asks for
/// it. `TextEditor` re-lays its entire buffer on every keystroke, so a megabyte
/// payload is not slow to edit — it is impossible.
enum BodyEditorLimit {
    static let bytes = 128 * 1024
    /// How much of an oversize body the read-only stand-in shows. Taken as a
    /// prefix of the `String`, which costs the preview rather than the payload.
    static let previewCharacters = 2_000
}

// MARK: - Identity

/// Cheap stand-in for "is this the same body as last time".
///
/// Comparing the `Data` itself would work and would be correct, but it is a
/// megabyte memcmp on every re-evaluation of a view that is re-evaluated on
/// every captured request. Length plus both ends separates the bodies a debug
/// tool actually sees.
struct BodyFingerprint: Hashable {

    private let byteCount: Int
    private let contentType: String?
    private let head: Int
    private let tail: Int

    var isLarge: Bool { byteCount > 32 * 1024 }

    init(data: Data?, contentType: String?) {
        let data = data ?? Data()
        byteCount = data.count
        self.contentType = contentType
        head = data.prefix(64).hashValue
        tail = data.suffix(64).hashValue
    }

    var cacheKey: NSString {
        "\(byteCount)-\(contentType ?? "")-\(head)-\(tail)" as NSString
    }
}

/// Keeps the last few rendered bodies, so scrolling a detail row out of a
/// `List` and back does not pay for the payload again.
///
/// Bounded by count rather than by bytes: entries are capped at the capture cap
/// each, and `NSCache` drops them under memory pressure anyway.
final class BodyRenderCache: @unchecked Sendable {

    static let shared = BodyRenderCache()

    private final class Box: NSObject {
        let value: RenderedBody
        init(_ value: RenderedBody) { self.value = value }
    }

    private let storage = NSCache<NSString, Box>()

    private init() { storage.countLimit = 8 }

    func value(for fingerprint: BodyFingerprint) -> RenderedBody? {
        storage.object(forKey: fingerprint.cacheKey)?.value
    }

    func store(_ body: RenderedBody, for fingerprint: BodyFingerprint) {
        storage.setObject(Box(body), forKey: fingerprint.cacheKey)
    }
}
#endif
