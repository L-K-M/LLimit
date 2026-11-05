import Foundation
import XCTest
@testable import QuotaCore

final class BenchmarkJSONDocumentTests: XCTestCase {
  func testIgnoredValuesAreFullyValidated() throws {
    for invalid in [
      #"{"ignored":[1,],"kept":"yes"}"#,
      #"{"ignored":{"x":true,},"kept":"yes"}"#,
      #"{"ignored":"bad\q","kept":"yes"}"#,
      #"{"ignored":01,"kept":"yes"}"#,
      #"{"ignored":1e,"kept":"yes"}"#,
      #"{"ignored":-.,"kept":"yes"}"#,
      #"{"ignored":tru,"kept":"yes"}"#,
      #"{"ignored":"unfinished,"kept":"yes"}"#,
      #"{"ignored":null,"kept":"yes"} false"#
    ] {
      let document = BenchmarkJSONDocument(Data(invalid.utf8))
      XCTAssertThrowsError(try document.fields(document.whole, keeping: ["kept"]), invalid)
    }
  }

  func testEscapedKeysAndUnicodeValuesPreserveExactEvidence() throws {
    let json = #"{"ignored":[null,true,false,-12.3e+4,{"nested":"☃"}],"\u006bept":"héllo\n☃\u2028end"}"#
    let document = BenchmarkJSONDocument(Data(json.utf8))
    let fields = try document.fields(document.whole, keeping: ["kept"])
    XCTAssertEqual(Set(fields.keys), ["kept"])
    XCTAssertEqual(try document.string(fields["kept"]), "héllo\n☃\u{2028}end")
  }

  func testMalformedUTF8InDiscardedStringIsRejected() throws {
    var data = Data(#"{"ignored":""#.utf8)
    data.append(contentsOf: [0xF0, 0x80, 0x80, 0x80])
    data.append(contentsOf: #"","kept":"yes"}"#.utf8)
    let document = BenchmarkJSONDocument(data)
    XCTAssertThrowsError(try document.fields(document.whole, keeping: ["kept"]))
  }
}
