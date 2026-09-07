import Adapters
import Foundation
import TerminalCore
import Testing

@Suite("§7.2 ファイル内容の段階的読み取り")
struct FileContentReaderTests {
  @Test(
    "空、改行なし、LF、CRLF の行数を固定する",
    arguments: [
      ("", 0), ("one", 1), ("one\n", 1), ("one\ntwo", 2), ("one\r\ntwo\r\n", 2),
    ])
  func countsLines(_ text: String, _ expectedLineCount: Int) throws {
    try withContentFile(Data(text.utf8)) { url in
      let result = try FileContentReader().read(url: url)
      #expect(result.observation == .text(byteCount: text.utf8.count, lineCount: expectedLineCount))
      #expect(result.text == text)
      #expect(result.decision == .display)
    }
  }

  @Test(
    "NUL と不正 UTF-8 はバイナリとして本文を返さない",
    arguments: [
      Data([65, 0, 66]), Data([0xC3, 0x28]),
    ])
  func detectsBinaryFiles(_ data: Data) throws {
    try withContentFile(data) { url in
      let result = try FileContentReader().read(url: url)
      #expect(result.observation == .binary(byteCount: data.count))
      #expect(result.text == nil)
      #expect(result.decision.confirmationReasons != nil)
    }
  }

  @Test("サイズ超過では実サイズだけを観測し行数と本文を読まない")
  func stopsAfterSampleForLargeText() throws {
    var data = Data(repeating: 65, count: 8_193)
    data[8_192] = 0xFF
    try withContentFile(data) { url in
      let result = try FileContentReader().read(
        url: url,
        thresholds: FileViewThresholds(maximumByteCount: 8_192, maximumLineCount: 50_000))
      #expect(result.observation == .text(byteCount: 8_193, lineCount: nil))
      #expect(result.text == nil)
    }
  }
}

private func withContentFile(_ data: Data, _ body: (URL) throws -> Void) throws {
  let url = URL(fileURLWithPath: "/private/tmp/awt-content-\(UUID().uuidString)")
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  try body(url)
}
