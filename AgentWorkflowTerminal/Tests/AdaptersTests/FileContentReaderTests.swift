import Darwin
import Foundation
import TerminalCore
import Testing

@testable import Adapters

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
      #expect(result.text?.content == text)
      #expect(result.text?.truncatedAtByteCount == nil)
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

  @Test("閾値ちょうどのサイズは行数を数えて本文を返す")
  func countsLinesAtByteThreshold() throws {
    try withContentFile(Data(repeating: 65, count: 8_192)) { url in
      let result = try FileContentReader().read(
        url: url,
        thresholds: FileViewThresholds(maximumByteCount: 8_192, maximumLineCount: 50_000))
      #expect(result.observation == .text(byteCount: 8_192, lineCount: 1))
      #expect(result.text?.content.utf8.count == 8_192)
      #expect(result.decision == .display)
    }
  }

  @Test("行数超過は確認前に本文を返さず、確認後に返す")
  func withholdsTextUntilLineCountConfirmed() throws {
    try withContentFile(Data("a\nb\nc\n".utf8)) { url in
      let thresholds = FileViewThresholds(maximumByteCount: 1_048_576, maximumLineCount: 2)
      let pending = try FileContentReader().read(url: url, thresholds: thresholds)
      #expect(pending.decision.confirmationReasons?.elements == [.lineCount(actual: 3, maximum: 2)])
      #expect(pending.text == nil)

      let confirmed = try FileContentReader().read(
        url: url, thresholds: thresholds, confirmation: .confirmed)
      #expect(confirmed.text?.content == "a\nb\nc\n")
      #expect(confirmed.text?.truncatedAtByteCount == nil)
    }
  }

  @Test("確認後はサイズ超過でも本文を返す")
  func returnsTextAfterConfirmation() throws {
    try withContentFile(Data(repeating: 65, count: 200)) { url in
      let result = try FileContentReader().read(
        url: url,
        thresholds: FileViewThresholds(maximumByteCount: 100, maximumLineCount: 50_000),
        confirmation: .confirmed)
      #expect(result.observation == .text(byteCount: 200, lineCount: 1))
      #expect(result.text?.content.utf8.count == 200)
      #expect(result.text?.truncatedAtByteCount == nil)
      #expect(
        result.decision.confirmationReasons?.elements == [.byteCount(actual: 200, maximum: 100)])
    }
  }

  @Test("確認後も絶対上限までしか読まず、打ち切りを結果に出す")
  func truncatesAtAbsoluteMaximum() throws {
    try withContentFile(Data(repeating: 65, count: 200)) { url in
      let result = try FileContentReader().read(
        url: url,
        thresholds: FileViewThresholds(
          maximumByteCount: 100, maximumLineCount: 50_000, absoluteMaximumByteCount: 150),
        confirmation: .confirmed)
      #expect(result.observation == .text(byteCount: 200, lineCount: nil))
      #expect(result.text?.content.utf8.count == 150)
      #expect(result.text?.truncatedAtByteCount == 150)
    }
  }

  @Test("打ち切りが文字の途中で起きても不完全なバイト列をバイナリと見なさない")
  func dropsIncompleteUTF8TailWhenTruncating() throws {
    // "あ" は 3 バイトなので、上限 4 は 2 文字目の途中で切れる。
    try withContentFile(Data("ああ".utf8)) { url in
      let result = try FileContentReader().read(
        url: url,
        thresholds: FileViewThresholds(
          maximumByteCount: 1, maximumLineCount: 50_000, absoluteMaximumByteCount: 4),
        confirmation: .confirmed)
      #expect(result.observation == .text(byteCount: 6, lineCount: nil))
      #expect(result.text?.content == "あ")
      #expect(result.text?.truncatedAtByteCount == 3)
    }
  }

  @Test("バイナリは確認後も本文を返さない")
  func neverReturnsBinaryContent() throws {
    try withContentFile(Data([65, 0, 66])) { url in
      let result = try FileContentReader().read(url: url, confirmation: .confirmed)
      #expect(result.text == nil)
    }
  }

  @Test("読んでいる途中でサイズが変わったら本文を返さず報告する")
  func reportsFileChangedDuringRead() throws {
    try withContentFile(Data("0123456789".utf8)) { url in
      let reader = FileContentReader(byteCountOfRegularFile: { _ in 3 })
      #expect(throws: FileContentReaderError.fileChanged(expected: 3, actual: 10)) {
        _ = try reader.read(url: url)
      }
    }
  }

  @Test("通常ファイル以外は開かず種別を名指しする", .timeLimit(.minutes(1)))
  func rejectsNonRegularFiles() throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-content-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.txt")
    try Data(repeating: 65, count: 1_200).write(to: target)
    let link = root.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let fifo = root.appending(path: "pipe")
    #expect(mkfifo(fifo.path, 0o644) == 0)
    let missing = root.appending(path: "nope")

    let reader = FileContentReader()
    #expect(throws: FileContentReaderError.notRegularFile(path: link.path, kind: .symbolicLink)) {
      _ = try reader.read(url: link)
    }
    #expect(throws: FileContentReaderError.notRegularFile(path: fifo.path, kind: .fifo)) {
      _ = try reader.read(url: fifo)
    }
    #expect(throws: FileContentReaderError.notRegularFile(path: root.path, kind: .directory)) {
      _ = try reader.read(url: root)
    }
    #expect(
      throws: FileContentReaderError.notRegularFile(path: "/dev/null", kind: .characterDevice)
    ) {
      _ = try reader.read(url: URL(fileURLWithPath: "/dev/null"))
    }
    #expect(throws: FileContentReaderError.statFailed(path: missing.path, code: ENOENT)) {
      _ = try reader.read(url: missing)
    }
  }
}

private func withContentFile(_ data: Data, _ body: (URL) throws -> Void) throws {
  let url = URL(fileURLWithPath: "/private/tmp/awt-content-\(UUID().uuidString)")
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  try body(url)
}
