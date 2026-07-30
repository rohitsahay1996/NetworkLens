//
//  JSONNodeTests.swift
//  NetworkLensCoreTests
//
//  Created by Rohit Sahay on 29/07/26.
//

import XCTest
@testable import NetworkLensCore

final class JSONNodeTests: XCTestCase {

    private func roundTrip(_ json: String) throws -> String {
        JSONNodeSerializer.string(from: try JSONNodeParser.parse(json))
    }

    // MARK: - Byte-level stability

    func testPreservesKeyOrder() throws {
        let json = #"{"zebra":1,"apple":2,"mango":3,"banana":4}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testPreservesDuplicateKeys() throws {
        let json = #"{"a":1,"a":2,"a":3}"#
        XCTAssertEqual(try roundTrip(json), json)

        guard case .object(let entries) = try JSONNodeParser.parse(json) else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.value.numberLiteral), ["1", "2", "3"])
    }

    func testPreservesFloatsEndingInZero() throws {
        let json = #"{"rate":1.0,"zero":0.0,"neg":-2.50}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testPreservesBigIntegersBeyondDoublePrecision() throws {
        let json = #"{"id":9007199254740993,"big":123456789012345678901234567890}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testPreservesExponentNotation() throws {
        let json = #"{"a":1e-7,"b":1E+10,"c":-3.5e2}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testPreservesEmptyContainers() throws {
        let json = #"{"obj":{},"arr":[],"nested":{"a":[],"b":{}}}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testDeepNesting() throws {
        let json = #"{"a":{"b":{"c":{"d":[{"e":[1,2,{"f":null}]}]}}}}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testMixedTypesAndNull() throws {
        let json = #"[1,"two",true,false,null,{"a":1},[2]]"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    // MARK: - Escapes

    func testUnicodeEscapesDecodeAndRoundTripIdempotently() throws {
        let node = try JSONNodeParser.parse(#"{"name":"Aé😀"}"#)
        XCTAssertEqual(node["name"]?.stringValue, "Aé😀")

        // Escape *spelling* is normalised on the first pass: escapes that are
        // not required by JSON are written back as literal characters.
        let once = JSONNodeSerializer.string(from: node)
        XCTAssertEqual(once, #"{"name":"Aé😀"}"#)

        // Every pass after that is byte-stable.
        let twice = JSONNodeSerializer.string(from: try JSONNodeParser.parse(once))
        XCTAssertEqual(twice, once)
    }

    func testRequiredEscapesArePreserved() throws {
        let json = #"{"s":"line\nbreak \"quoted\" back\\slash \ttab"}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    func testControlCharactersAreEscaped() throws {
        let node = JSONNode.object([.init(key: "s", value: .string("\u{01}"))])
        XCTAssertEqual(JSONNodeSerializer.string(from: node), #"{"s":"\u0001"}"#)
    }

    func testSolidusEscapeIsNormalised() throws {
        let node = try JSONNodeParser.parse(#"{"path":"a\/b"}"#)
        XCTAssertEqual(node["path"]?.stringValue, "a/b")
        XCTAssertEqual(JSONNodeSerializer.string(from: node), #"{"path":"a/b"}"#)
    }

    func testRawUnicodeInStringsSurvives() throws {
        let json = #"{"greeting":"héllo 世界 🎉"}"#
        XCTAssertEqual(try roundTrip(json), json)
    }

    // MARK: - Whitespace and formatting

    func testInsignificantWhitespaceIsDropped() throws {
        let json = "{\n  \"a\" : 1 ,\n  \"b\" : [ 1 , 2 ]\n}"
        XCTAssertEqual(try roundTrip(json), #"{"a":1,"b":[1,2]}"#)
    }

    func testPrettyFormatRoundTripsToTheSameTree() throws {
        let json = #"{"a":{"b":[1,2.0,"x"]},"c":null}"#
        let node = try JSONNodeParser.parse(json)
        let pretty = JSONNodeSerializer.string(from: node, format: .pretty)
        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertEqual(try JSONNodeParser.parse(pretty), node)
        XCTAssertEqual(JSONNodeSerializer.string(from: try JSONNodeParser.parse(pretty)), json)
    }

    // MARK: - Errors

    func testRejectsTrailingBytes() {
        XCTAssertThrowsError(try JSONNodeParser.parse(#"{"a":1} garbage"#))
    }

    func testRejectsUnterminatedString() {
        XCTAssertThrowsError(try JSONNodeParser.parse(#"{"a":"x}"#))
    }

    func testRejectsTrailingComma() {
        XCTAssertThrowsError(try JSONNodeParser.parse(#"{"a":1,}"#))
        XCTAssertThrowsError(try JSONNodeParser.parse("[1,2,]"))
    }

    func testRejectsLeadingPlusAndBareDecimal() {
        XCTAssertThrowsError(try JSONNodeParser.parse("[+1]"))
        XCTAssertThrowsError(try JSONNodeParser.parse("[1.]"))
    }

    func testRejectsUnpairedSurrogate() {
        XCTAssertThrowsError(try JSONNodeParser.parse(#"{"a":"\ud83d"}"#))
    }

    // MARK: - Accessors

    func testAccessors() throws {
        let node = try JSONNodeParser.parse(#"{"n":1.50,"s":"x","b":true,"z":null,"arr":[7]}"#)
        XCTAssertEqual(node["n"]?.numberLiteral, "1.50")
        XCTAssertEqual(node["n"]?.doubleValue, 1.5)
        XCTAssertEqual(node["s"]?.stringValue, "x")
        XCTAssertEqual(node["b"]?.boolValue, true)
        XCTAssertEqual(node["z"]?.isNull, true)
        XCTAssertEqual(node["arr"]?[0]?.numberLiteral, "7")
        XCTAssertNil(node["missing"])
        XCTAssertNil(node["arr"]?[5])
    }
}
