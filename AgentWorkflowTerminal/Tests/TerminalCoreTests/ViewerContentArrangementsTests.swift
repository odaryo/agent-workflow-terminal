import Foundation
import TerminalCore
import Testing

@Suite("Viewer の並びの保存値 (設計書 §6.1)")
struct ViewerContentArrangementsTests {
  @Test("既定値は Code が左右、Diff が上下")
  func defaults() {
    let arrangements = ViewerContentArrangements()
    #expect(arrangements == .defaults)
    #expect(arrangements.code == .sideBySide)
    #expect(arrangements.diff == .stacked)
    #expect(ViewerContentArrangements(code: .stacked).diff == .stacked)
    #expect(ViewerContentArrangements(diff: .sideBySide).code == .sideBySide)
  }

  @Test(
    "全ての並びの組み合わせが JSON の往復で保たれる",
    arguments: ViewerContentArrangement.allCases, ViewerContentArrangement.allCases)
  func roundTrips(code: ViewerContentArrangement, diff: ViewerContentArrangement) throws {
    let original = ViewerContentArrangements(code: code, diff: diff)
    let data = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(ViewerContentArrangements.self, from: data)
    #expect(restored == original)
  }

  @Test(
    "JSON は code / diff キーと sideBySide / stacked 値を使う",
    arguments: [
      (
        ViewerContentArrangement.sideBySide, ViewerContentArrangement.stacked, "sideBySide",
        "stacked"
      ),
      (.stacked, .sideBySide, "stacked", "sideBySide"),
    ])
  func encodedSchema(
    code: ViewerContentArrangement, diff: ViewerContentArrangement,
    codeValue: String, diffValue: String
  ) throws {
    let data = try JSONEncoder().encode(ViewerContentArrangements(code: code, diff: diff))
    let object = try JSONDecoder().decode([String: String].self, from: data)
    #expect(object == ["code": codeValue, "diff": diffValue])
  }

  @Test(
    "欠けたキー・未知の値だけを既定値に戻して復号できる",
    arguments: [
      (#"{}"#, ViewerContentArrangement.sideBySide, ViewerContentArrangement.stacked),
      (#"{"code":"stacked"}"#, .stacked, .stacked),
      (#"{"diff":"sideBySide"}"#, .sideBySide, .sideBySide),
      (#"{"code":"diagonal","diff":"sideBySide"}"#, .sideBySide, .sideBySide),
      (#"{"code":"stacked","diff":"diagonal"}"#, .stacked, .stacked),
      (#"{"code":"diagonal","diff":"diagonal"}"#, .sideBySide, .stacked),
    ])
  func decodesWithPerKeyDefaults(
    json: String, code: ViewerContentArrangement, diff: ViewerContentArrangement
  ) throws {
    let restored = try JSONDecoder().decode(
      ViewerContentArrangements.self, from: Data(json.utf8))
    #expect(restored.code == code)
    #expect(restored.diff == diff)
  }
}
