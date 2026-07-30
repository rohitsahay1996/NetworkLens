//
//  JSONDiffTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 29/07/26.
//

import XCTest
@testable import NetworkLensCore

final class JSONDiffTests: XCTestCase {

    private func parse(_ json: String) throws -> JSONNode {
        try JSONNodeParser.parse(json)
    }

    /// The invariant the whole perturbation feature rests on: ops generated
    /// from a diff must reproduce the edit byte for byte.
    private func assertRoundTrip(
        _ originalJSON: String,
        _ editedJSON: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let original = try parse(originalJSON)
        let edited = try parse(editedJSON)
        let ops = JSONDiff.ops(from: original, to: edited)
        let replayed = try original.applying(ops)

        XCTAssertEqual(
            JSONNodeSerializer.string(from: replayed),
            JSONNodeSerializer.string(from: edited),
            "generated ops did not reproduce the edit: \(ops.map(\.summary))",
            file: file, line: line
        )
    }

    // MARK: - Round trips

    func testNoChangeProducesNoOps() throws {
        let tree = try parse(#"{"a":1,"b":[1,2]}"#)
        XCTAssertTrue(JSONDiff.ops(from: tree, to: tree).isEmpty)
    }

    func testLeafChange() throws {
        try assertRoundTrip(#"{"stock":12}"#, #"{"stock":0}"#)
    }

    func testNestedLeafChange() throws {
        try assertRoundTrip(
            #"{"data":{"items":[{"stock":5},{"stock":9}]}}"#,
            #"{"data":{"items":[{"stock":5},{"stock":0}]}}"#
        )
    }

    func testAddedMember() throws {
        try assertRoundTrip(#"{"a":1}"#, #"{"a":1,"b":2}"#)
    }

    func testRemovedMember() throws {
        try assertRoundTrip(#"{"a":1,"b":2,"c":3}"#, #"{"a":1,"c":3}"#)
    }

    func testAddedAndRemovedTogether() throws {
        try assertRoundTrip(#"{"a":1,"b":2}"#, #"{"a":1,"c":3}"#)
    }

    func testArrayElementAppended() throws {
        try assertRoundTrip(#"{"items":[1,2]}"#, #"{"items":[1,2,3]}"#)
    }

    func testArrayTruncated() throws {
        try assertRoundTrip(#"{"items":[1,2,3,4]}"#, #"{"items":[1,2]}"#)
    }

    func testArrayEmptied() throws {
        try assertRoundTrip(#"{"variants":[{"a":1},{"a":2}]}"#, #"{"variants":[]}"#)
    }

    func testTypeChange() throws {
        try assertRoundTrip(#"{"a":{"b":1}}"#, #"{"a":null}"#)
    }

    func testDeepNesting() throws {
        try assertRoundTrip(
            #"{"a":{"b":{"c":{"d":[{"e":[1,2,{"f":null}]}]}}}}"#,
            #"{"a":{"b":{"c":{"d":[{"e":[1,7,{"f":"x"}]}]}}}}"#
        )
    }

    func testUnrelatedNodesKeepOrderAndLiterals() throws {
        try assertRoundTrip(
            #"{"z":1.0,"target":1,"big":9007199254740993,"m":1e-7}"#,
            #"{"z":1.0,"target":0,"big":9007199254740993,"m":1e-7}"#
        )
    }

    func testDuplicateKeysFallBackToWholeObjectReplace() throws {
        try assertRoundTrip(#"{"a":1,"a":2}"#, #"{"a":1,"a":3}"#)
    }

    func testReorderedKeysRoundTrip() throws {
        try assertRoundTrip(#"{"a":1,"b":2}"#, #"{"b":2,"a":1}"#)
    }

    // MARK: - Op shape

    func testLeafChangeProducesSingleReplace() throws {
        let ops = JSONDiff.ops(
            from: try parse(#"{"data":{"stock":5,"name":"x"}}"#),
            to: try parse(#"{"data":{"stock":0,"name":"x"}}"#)
        )
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops[0].kind, .replace)
        XCTAssertEqual(ops[0].path.description, "/data/stock")
        XCTAssertEqual(ops[0].value?.numberLiteral, "0")
    }

    func testRemovalsComeBeforeAdditions() throws {
        let ops = JSONDiff.ops(
            from: try parse(#"{"old":1,"keep":2}"#),
            to: try parse(#"{"keep":2,"new":3}"#)
        )
        let kinds = ops.map(\.kind)
        if let removeIndex = kinds.firstIndex(of: .remove),
           let addIndex = kinds.firstIndex(of: .add) {
            XCTAssertLessThan(removeIndex, addIndex)
        }
    }

    func testArrayShrinkRemovesFromTheBack() throws {
        // Removing front-first would invalidate the trailing indices.
        let ops = JSONDiff.ops(
            from: try parse(#"[1,2,3,4]"#),
            to: try parse(#"[1,2]"#)
        )
        XCTAssertEqual(ops.map(\.path.description), ["/3", "/2"])
    }

    // MARK: - Replay against a different payload

    /// The acceptance criterion: a saved perturbation must work against a
    /// *different* response for the same endpoint, not just the one it was
    /// captured from.
    func testPerturbationReplaysAgainstDifferentPayload() throws {
        let captured = try parse(#"{"data":{"items":[{"id":1,"stock":5}]},"page":1}"#)
        let edited = try parse(#"{"data":{"items":[{"id":1,"stock":0}]},"page":1}"#)

        let perturbation = Perturbation(
            name: "out_of_stock",
            endpointKey: "GET /items",
            ops: JSONDiff.ops(from: captured, to: edited),
            verifiedAgainstShape: captured.shapeHash
        )

        // Same shape, entirely different values and an extra element.
        let laterResponse = try parse(
            #"{"data":{"items":[{"id":77,"stock":42},{"id":78,"stock":9}]},"page":3}"#
        )
        let (result, drifted) = try perturbation.apply(to: laterResponse)

        XCTAssertFalse(drifted)
        XCTAssertEqual(
            JSONNodeSerializer.string(from: result),
            #"{"data":{"items":[{"id":77,"stock":0},{"id":78,"stock":9}]},"page":3}"#
        )
    }

    func testShapeDriftIsReported() throws {
        let captured = try parse(#"{"data":{"stock":5}}"#)
        let edited = try parse(#"{"data":{"stock":0}}"#)
        let perturbation = Perturbation(
            name: "zero",
            endpointKey: "GET /x",
            ops: JSONDiff.ops(from: captured, to: edited),
            verifiedAgainstShape: captured.shapeHash
        )

        // Server added a field: the contract moved under the saved edit.
        let drifted = try parse(#"{"data":{"stock":5,"reserved":2}}"#)
        XCTAssertTrue(try perturbation.apply(to: drifted).shapeDrifted)
    }

    // MARK: - Hashes

    func testShapeHashIgnoresValuesAndArrayLength() throws {
        let a = try parse(#"{"items":[{"id":1,"name":"x"}]}"#)
        let b = try parse(#"{"items":[{"id":99,"name":"zzz"},{"id":100,"name":"q"}]}"#)
        XCTAssertEqual(a.shapeHash, b.shapeHash)
    }

    func testShapeHashChangesWhenKeysChange() throws {
        let a = try parse(#"{"items":[{"id":1}]}"#)
        let b = try parse(#"{"items":[{"id":1,"extra":2}]}"#)
        XCTAssertNotEqual(a.shapeHash, b.shapeHash)
    }

    func testContentHashIsOrderSensitive() throws {
        let a = try parse(#"{"a":1,"b":2}"#)
        let b = try parse(#"{"b":2,"a":1}"#)
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    func testContentHashIsStable() throws {
        let json = #"{"a":1.0,"b":[1,2]}"#
        XCTAssertEqual(try parse(json).contentHash, try parse(json).contentHash)
    }
}
