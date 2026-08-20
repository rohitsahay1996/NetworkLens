//
//  PatchOpTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 29/07/26.
//

import XCTest
@testable import NetworkLensCore

final class JSONPointerTests: XCTestCase {

    func testParsesTokens() throws {
        XCTAssertEqual(try JSONPointer(string: "/data/items/0/stock").tokens,
                       ["data", "items", "0", "stock"])
    }

    func testRootIsEmpty() throws {
        XCTAssertTrue(try JSONPointer(string: "").isRoot)
    }

    func testEmptyKeyIsLegal() throws {
        XCTAssertEqual(try JSONPointer(string: "/").tokens, [""])
    }

    func testUnescapesInCorrectOrder() throws {
        // "~01" must decode to "~1", not to "/". Unescaping ~0 first would
        // produce "~1" and then wrongly decode that to "/".
        XCTAssertEqual(try JSONPointer(string: "/a~01b").tokens, ["a~1b"])
        XCTAssertEqual(try JSONPointer(string: "/a~1b").tokens, ["a/b"])
        XCTAssertEqual(try JSONPointer(string: "/a~0b").tokens, ["a~b"])
    }

    func testDescriptionRoundTrips() throws {
        for raw in ["/a/b", "/a~1b", "/a~0b", "/a~01b", "/", "/0/1"] {
            XCTAssertEqual(try JSONPointer(string: raw).description, raw)
        }
    }

    func testRejectsPointerWithoutLeadingSlash() {
        XCTAssertThrowsError(try JSONPointer(string: "data/items"))
    }

    func testCodableRoundTrip() throws {
        let pointer = try JSONPointer(string: "/a~1b/0")
        let data = try JSONEncoder().encode(pointer)
        XCTAssertEqual(try JSONDecoder().decode(JSONPointer.self, from: data), pointer)
    }
}

final class PatchOpApplicationTests: XCTestCase {

    private func parse(_ json: String) throws -> JSONNode {
        try JSONNodeParser.parse(json)
    }

    private func render(_ node: JSONNode) -> String {
        JSONNodeSerializer.string(from: node)
    }

    // MARK: - Replace

    func testReplaceLeaf() throws {
        let tree = try parse(#"{"data":{"stock":12,"name":"Widget"}}"#)
        let op = try PatchOp(kind: .replace, path: "/data/stock", value: .number("0"))
        XCTAssertEqual(render(try tree.applying(op)), #"{"data":{"stock":0,"name":"Widget"}}"#)
    }

    func testReplaceInsideNestedArray() throws {
        let tree = try parse(#"{"data":{"items":[{"stock":5},{"stock":9}]}}"#)
        let op = try PatchOp(kind: .replace, path: "/data/items/1/stock", value: .number("0"))
        XCTAssertEqual(
            render(try tree.applying(op)),
            #"{"data":{"items":[{"stock":5},{"stock":0}]}}"#
        )
    }

    func testReplacePreservesSiblingOrderAndNumberLiterals() throws {
        let tree = try parse(#"{"z":1.0,"target":1,"a":9007199254740993,"m":1e-7}"#)
        let op = try PatchOp(kind: .replace, path: "/target", value: .string("x"))
        XCTAssertEqual(
            render(try tree.applying(op)),
            #"{"z":1.0,"target":"x","a":9007199254740993,"m":1e-7}"#
        )
    }

    func testReplaceRootReturnsValue() throws {
        let tree = try parse(#"{"a":1}"#)
        let op = PatchOp(kind: .replace, path: JSONPointer(tokens: []), value: .null)
        XCTAssertEqual(render(try tree.applying(op)), "null")
    }

    func testReplaceChangesType() throws {
        let tree = try parse(#"{"a":{"b":1}}"#)
        let op = try PatchOp(kind: .replace, path: "/a", value: .array([.number("1")]))
        XCTAssertEqual(render(try tree.applying(op)), #"{"a":[1]}"#)
    }

    // MARK: - Remove

    func testRemoveObjectMember() throws {
        let tree = try parse(#"{"a":1,"b":2,"c":3}"#)
        let op = try PatchOp(kind: .remove, path: "/b")
        XCTAssertEqual(render(try tree.applying(op)), #"{"a":1,"c":3}"#)
    }

    func testRemoveArrayElement() throws {
        let tree = try parse(#"{"items":[1,2,3]}"#)
        let op = try PatchOp(kind: .remove, path: "/items/1")
        XCTAssertEqual(render(try tree.applying(op)), #"{"items":[1,3]}"#)
    }

    // MARK: - Add

    func testAddNewObjectMemberAppends() throws {
        let tree = try parse(#"{"a":1}"#)
        let op = try PatchOp(kind: .add, path: "/b", value: .number("2"))
        XCTAssertEqual(render(try tree.applying(op)), #"{"a":1,"b":2}"#)
    }

    func testAddOverExistingMemberReplacesInPlace() throws {
        let tree = try parse(#"{"a":1,"b":2}"#)
        let op = try PatchOp(kind: .add, path: "/a", value: .number("9"))
        XCTAssertEqual(render(try tree.applying(op)), #"{"a":9,"b":2}"#)
    }

    func testAddToArrayAtIndexInserts() throws {
        let tree = try parse(#"{"items":[1,3]}"#)
        let op = try PatchOp(kind: .add, path: "/items/1", value: .number("2"))
        XCTAssertEqual(render(try tree.applying(op)), #"{"items":[1,2,3]}"#)
    }

    func testAddToArrayWithDashAppends() throws {
        let tree = try parse(#"{"items":[1,2]}"#)
        let op = try PatchOp(kind: .add, path: "/items/-", value: .number("3"))
        XCTAssertEqual(render(try tree.applying(op)), #"{"items":[1,2,3]}"#)
    }

    func testAddAtEndIndexIsAllowed() throws {
        let tree = try parse(#"{"items":[1,2]}"#)
        let op = try PatchOp(kind: .add, path: "/items/2", value: .number("3"))
        XCTAssertEqual(render(try tree.applying(op)), #"{"items":[1,2,3]}"#)
    }

    // MARK: - Failure modes

    func testMissingObjectPathThrows() throws {
        let tree = try parse(#"{"a":1}"#)
        let op = try PatchOp(kind: .replace, path: "/nope", value: .null)
        XCTAssertThrowsError(try tree.applying(op)) { error in
            XCTAssertEqual(error as? PatchError, .pathNotFound("/nope"))
        }
    }

    func testMissingNestedPathThrows() throws {
        let tree = try parse(#"{"a":{"b":1}}"#)
        let op = try PatchOp(kind: .replace, path: "/a/c/d", value: .null)
        XCTAssertThrowsError(try tree.applying(op))
    }

    func testDescendingIntoLeafThrows() throws {
        let tree = try parse(#"{"a":"text"}"#)
        let op = try PatchOp(kind: .replace, path: "/a/b", value: .null)
        XCTAssertThrowsError(try tree.applying(op)) { error in
            XCTAssertEqual(error as? PatchError, .notAContainer(path: "/a/b", found: "a string"))
        }
    }

    func testOutOfRangeArrayIndexThrows() throws {
        let tree = try parse(#"{"items":[1,2]}"#)
        let op = try PatchOp(kind: .replace, path: "/items/5", value: .null)
        XCTAssertThrowsError(try tree.applying(op)) { error in
            XCTAssertEqual(error as? PatchError, .invalidArrayIndex(path: "/items/5", token: "5"))
        }
    }

    func testNonNumericArrayIndexThrows() throws {
        let tree = try parse(#"{"items":[1,2]}"#)
        let op = try PatchOp(kind: .replace, path: "/items/first", value: .null)
        XCTAssertThrowsError(try tree.applying(op))
    }

    func testLeadingZeroArrayIndexThrows() throws {
        let tree = try parse(#"{"items":[1,2]}"#)
        let op = try PatchOp(kind: .replace, path: "/items/01", value: .null)
        XCTAssertThrowsError(try tree.applying(op))
    }

    func testReplaceWithoutValueThrows() throws {
        let tree = try parse(#"{"a":1}"#)
        let op = try PatchOp(kind: .replace, path: "/a", value: nil)
        XCTAssertThrowsError(try tree.applying(op)) { error in
            XCTAssertEqual(error as? PatchError, .missingValue(path: "/a"))
        }
    }

    func testFailedOpLeavesOriginalUntouched() throws {
        let tree = try parse(#"{"a":1,"b":2}"#)
        let ops = [
            try PatchOp(kind: .replace, path: "/a", value: .number("9")),
            try PatchOp(kind: .replace, path: "/missing", value: .null),
        ]
        XCTAssertThrowsError(try tree.applying(ops))
        // Value semantics mean the caller's tree cannot be left half-patched.
        XCTAssertEqual(render(tree), #"{"a":1,"b":2}"#)
    }

    // MARK: - Reads

    func testValueAtPointer() throws {
        let tree = try parse(#"{"data":{"items":[{"stock":5}]}}"#)
        XCTAssertEqual(try tree.value(at: JSONPointer(string: "/data/items/0/stock"))?.numberLiteral, "5")
        XCTAssertNil(try tree.value(at: JSONPointer(string: "/data/items/9")))
        XCTAssertNil(try tree.value(at: JSONPointer(string: "/nope")))
    }

    // MARK: - Pointers built by walking a tree

    /// The tree editor addresses nodes by building a pointer token by token as
    /// it walks. That only works if a built pointer round-trips through its own
    /// text form — which it does *because* `description` escapes. The old tree
    /// interpolated `"\(path)/\(key)"` by hand and did not escape, so a key
    /// with a slash in it silently addressed the wrong node.
    func testAPointerBuiltByAppendingSurvivesItsOwnTextForm() throws {
        let pointer = JSONPointer(tokens: []).appending("a/b").appending("c~d")

        XCTAssertEqual(pointer.description, "/a~1b/c~0d")
        XCTAssertEqual(try JSONPointer(string: pointer.description), pointer)
        XCTAssertEqual(pointer.tokens, ["a/b", "c~d"])
    }

    /// The failure the escaping prevents: without it, `"a/b"` reads back as two
    /// tokens and resolves to a node nobody asked for.
    func testAKeyContainingASlashAddressesItsOwnNode() throws {
        let tree = try parse(#"{"a/b":{"stock":5},"a":{"b":{"stock":99}}}"#)
        let pointer = JSONPointer(tokens: []).appending("a/b").appending("stock")

        XCTAssertEqual(tree.value(at: pointer)?.numberLiteral, "5")

        let edited = try tree.applying(PatchOp(kind: .replace, path: pointer, value: .number("0")))
        XCTAssertEqual(edited.value(at: pointer)?.numberLiteral, "0")
        // The lookalike is untouched.
        XCTAssertEqual(
            edited.value(at: try JSONPointer(string: "/a/b/stock"))?.numberLiteral,
            "99"
        )
    }

    func testAKeyContainingATildeAddressesItsOwnNode() throws {
        let tree = try parse(#"{"a~b":1,"a":2}"#)
        let pointer = JSONPointer(tokens: []).appending("a~b")

        XCTAssertEqual(tree.value(at: pointer)?.numberLiteral, "1")
        XCTAssertEqual(pointer.description, "/a~0b")
    }

    // MARK: - Staged edits

    /// What the tree editor stages when someone taps "Empty this list" and then
    /// edits a field: ops accumulate against the original and replay in order.
    func testStagedOpsReplayFromTheOriginal() throws {
        let tree = try parse(#"{"items":[1,2,3],"total":3}"#)
        let ops = [
            PatchOp(kind: .replace, path: try JSONPointer(string: "/items"), value: .array([])),
            PatchOp(kind: .replace, path: try JSONPointer(string: "/total"), value: .number("0")),
        ]

        let edited = try tree.applying(ops)

        XCTAssertEqual(JSONNodeSerializer.string(from: edited), #"{"items":[],"total":0}"#)
        // The original is a value type and stays exactly as captured.
        XCTAssertEqual(JSONNodeSerializer.string(from: tree), #"{"items":[1,2,3],"total":3}"#)
    }

    /// "Duplicate ×N" appends copies of a row the server actually sent, so a
    /// paginated screen can be pushed past its page size without invented data.
    func testDuplicatingAnElementAppendsCopies() throws {
        let tree = try parse(#"{"items":[{"id":1}]}"#)
        let element = try XCTUnwrap(tree.value(at: try JSONPointer(string: "/items/0")))
        let append = PatchOp(
            kind: .add, path: try JSONPointer(string: "/items/-"), value: element
        )

        let edited = try tree.applying([append, append, append])

        guard case .object(let entries) = edited,
              case .array(let items) = entries[0].value else {
            return XCTFail("expected items to still be an array")
        }
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.last, element)
    }

    /// An op whose pointer no longer resolves must throw rather than silently
    /// doing nothing — the editor drops it and says so instead of leaving a
    /// list of edits that can never be applied again.
    func testAnOpAgainstARemovedParentThrows() throws {
        let tree = try parse(#"{"data":{"items":[1]}}"#)
        let remove = PatchOp(kind: .remove, path: try JSONPointer(string: "/data"))
        let intoRemoved = PatchOp(
            kind: .replace, path: try JSONPointer(string: "/data/items"), value: .array([])
        )

        XCTAssertThrowsError(try tree.applying([remove, intoRemoved]))
    }

    // MARK: - Codable

    func testPatchOpCodableRoundTrip() throws {
        let op = try PatchOp(kind: .replace, path: "/a/0", value: .number("1.50"))
        let data = try JSONEncoder().encode(op)
        let decoded = try JSONDecoder().decode(PatchOp.self, from: data)
        XCTAssertEqual(decoded, op)
        // The number literal must survive the encode/decode, not become 1.5.
        XCTAssertEqual(decoded.value?.numberLiteral, "1.50")
    }
}
