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
      let reader = FileContentReader(openRegularFile: openReportingThreeBytes)
      #expect(throws: FileContentReaderError.fileChanged(expected: 3, actual: 10)) {
        _ = try reader.read(url: url)
      }
    }
  }

  @Test("読取中に増大しても絶対上限を超えて読まない")
  func boundsReadWhenFileGrowsDuringRead() throws {
    try withContentFile(Data(repeating: 65, count: 32)) { url in
      let probe = try #require(OffsetProbe())
      let reader = FileContentReader { (url: URL) throws(FileContentReaderError) in
        let opened = try FileContentReader.openRegularFile(at: url)
        appendBytes(count: 4_096, to: url)
        probe.observe(opened.handle)
        return opened
      }

      #expect(throws: FileContentReaderError.fileChanged(expected: 32, actual: 4_128)) {
        _ = try reader.read(
          url: url,
          thresholds: FileViewThresholds(
            maximumByteCount: 16, maximumLineCount: 50_000, absoluteMaximumByteCount: 64),
          confirmation: .confirmed)
      }
      // 本文 32 バイトと、増大を検知するための 1 バイトだけ。修正前はここが 4_128 だった。
      #expect(probe.readByteCount == 33)
    }
  }

  @Test("打ち切る場合も読取中の増大につられて上限を超えて読まない")
  func boundsReadWhenTruncatedFileGrowsDuringRead() throws {
    // サンプル (8 KiB) は絶対上限より先に読むので、上限をそれより大きく取らないと
    // 「上限までしか読んでいない」を offset で測れない。
    try withContentFile(Data(repeating: 65, count: 20_000)) { url in
      let probe = try #require(OffsetProbe())
      let reader = FileContentReader { (url: URL) throws(FileContentReaderError) in
        let opened = try FileContentReader.openRegularFile(at: url)
        appendBytes(count: 40_000, to: url)
        probe.observe(opened.handle)
        return opened
      }

      let result = try reader.read(
        url: url,
        thresholds: FileViewThresholds(
          maximumByteCount: 16, maximumLineCount: 50_000, absoluteMaximumByteCount: 12_000),
        confirmation: .confirmed)
      #expect(result.observation == .text(byteCount: 20_000, lineCount: nil))
      #expect(result.text?.truncatedAtByteCount == 12_000)
      #expect(probe.readByteCount == 12_000)
    }
  }

  @Test("通常ファイル以外は開かず種別を名指しする", .timeLimit(.minutes(1)))
  func rejectsNonRegularFiles() async throws {
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

    #expect(
      await readOutcome(of: link) == .failed(.notRegularFile(path: link.path, kind: .symbolicLink)))
    #expect(await readOutcome(of: fifo) == .failed(.notRegularFile(path: fifo.path, kind: .fifo)))
    #expect(
      await readOutcome(of: root) == .failed(.notRegularFile(path: root.path, kind: .directory)))
    #expect(
      await readOutcome(of: URL(fileURLWithPath: "/dev/null"))
        == .failed(.notRegularFile(path: "/dev/null", kind: .characterDevice)))
    #expect(
      await readOutcome(of: missing) == .failed(.statFailed(path: missing.path, code: ENOENT)))
  }
}

private enum ReadOutcome: Equatable, Sendable {
  case timedOut
  case failed(FileContentReaderError)
  case failedOtherwise(String)
  case succeeded
}

private func openReportingThreeBytes(
  _ url: URL
) throws(FileContentReaderError) -> OpenedRegularFile {
  OpenedRegularFile(handle: try FileContentReader.openRegularFile(at: url).handle, byteCount: 3)
}

/// reader が handle を閉じた後に「どこまで読み進めたか」を測るための複製。複製は元と同じ open
/// file description を指すので offset を共有し、元を閉じた後も残る (計測: 元で 33 バイト読んだ
/// 直後の複製の offset が 33、元を `close` した後も `lseek` と `read` が成功した)。
///
/// 番号を `/dev/null` で先に押さえて `dup2` するのは、複製を作るのが seam の `@Sendable`
/// クロージャの中で、`dup(2)` が返す番号をその外へ書き出す先が無いため。番号を後から入れる
/// `var` を持たせると `Sendable` 適合が通らない (実測: "stored property 'descriptor' of
/// 'Sendable'-conforming class 'OffsetProbe' is mutable")。格納プロパティを不変に保てば、
/// 可変なのは kernel の fd table 側だけになる。
private final class OffsetProbe: Sendable {
  private let descriptor: Int32

  init?() {
    let descriptor = open("/dev/null", O_RDONLY)
    guard descriptor >= 0 else { return nil }
    self.descriptor = descriptor
  }

  deinit { close(descriptor) }

  func observe(_ handle: FileHandle) {
    _ = dup2(handle.fileDescriptor, descriptor)
  }

  var readByteCount: Int { Int(lseek(descriptor, 0, SEEK_CUR)) }
}

/// 追記の失敗は握り潰す。追記されなければ呼び出し側の主張 (増大後のサイズ・読取量) が落ちる。
private func appendBytes(count: Int, to url: URL) {
  let descriptor = open(url.path, O_WRONLY | O_APPEND)
  guard descriptor >= 0 else { return }
  let bytes = [UInt8](repeating: 66, count: count)
  _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
  close(descriptor)
}

/// `open(2)` は同期でキャンセルできないため、種別ガードが壊れると `.timeLimit` も `Task` の
/// キャンセルも効かず、テストプロセスごと止まる (計測: 変異を当てたテストが 23 分生き残り、
/// `defer` が走らず一時ディレクトリが残った)。別スレッドで読み、期限内に戻らないことを失敗にする。
private func readOutcome(of url: URL, within limit: Duration = .seconds(5)) async -> ReadOutcome {
  let outcomes = AsyncStream<ReadOutcome> { continuation in
    Thread.detachNewThread {
      do {
        _ = try FileContentReader().read(url: url)
        continuation.yield(.succeeded)
      } catch let error as FileContentReaderError {
        continuation.yield(.failed(error))
      } catch {
        continuation.yield(.failedOtherwise("\(error)"))
      }
      continuation.finish()
    }
  }
  return await withTaskGroup(of: ReadOutcome.self) { group in
    group.addTask {
      for await outcome in outcomes { return outcome }
      return .timedOut
    }
    group.addTask {
      try? await ContinuousClock().sleep(for: limit)
      return .timedOut
    }
    let first = await group.next() ?? .timedOut
    group.cancelAll()
    return first
  }
}

private func withContentFile(_ data: Data, _ body: (URL) throws -> Void) throws {
  let url = URL(fileURLWithPath: "/private/tmp/awt-content-\(UUID().uuidString)")
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  try body(url)
}
