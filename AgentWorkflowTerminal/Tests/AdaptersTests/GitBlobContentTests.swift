import CryptoKit
import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// 過去版 (`cat-file blob` の出力) に、現在のファイル (`FileContentReader`) と同じ §7.2 の
/// 判定を適用する。同じバイト列を一時ファイルにも書き、両者の結果が一致することで確かめる。
@Suite("§7.2 / §7.3 過去版の本文に現在のファイルと同じ判定を適用する")
struct GitBlobContentTests {
  private static let thresholds = FileViewThresholds(
    maximumByteCount: 64, maximumLineCount: 3, absoluteMaximumByteCount: 16_384)

  private static let validCases: [(String, [UInt8])] = [
    ("小さいテキスト", Array("a\nb\n".utf8)),
    ("空", []),
    ("非 ASCII", Array("日本語\n".utf8)),
    ("改行で終わらない", Array("x\ny".utf8)),
    ("先頭付近の NUL", Array("ab".utf8) + [0] + Array("c\n".utf8)),
    ("8 KiB の最後のバイトが NUL", Array(repeating: UInt8(ascii: "a"), count: 8_191) + [0]),
    ("NUL が 8 KiB より後ろ", Array(repeating: UInt8(ascii: "a"), count: 8_192) + [0]),
    ("サイズ閾値を超えるテキスト", Array(repeating: UInt8(ascii: "a"), count: 100)),
    ("行数閾値を超えるテキスト", Array("1\n2\n3\n4\n".utf8)),
  ]

  @Test(
    "不正 UTF-8 を含まない内容は、現在のファイルと同じ結果になる",
    arguments: validCases.map(\.0), [FileOpenConfirmation.notConfirmed, .confirmed])
  func matchesFileContentReader(name: String, confirmation: FileOpenConfirmation) throws {
    let bytes = try #require(Self.validCases.first { $0.0 == name }?.1)
    let expected = try readThroughFileContentReader(bytes, confirmation: confirmation)

    let actual = GitBlobContent.classify(
      stdout: String(decoding: bytes, as: UTF8.self), byteCount: bytes.count,
      objectID: Self.blobID(of: bytes),
      thresholds: Self.thresholds, confirmation: confirmation)

    #expect(actual == expected)
  }

  private static let invalidCases: [(String, (bytes: [UInt8], isBinary: Bool))] = [
    ("小さい latin1", (Array("caf".utf8) + [0xE9, 0x0A], false)),
    ("元の位置 8191 の NUL", ([0xFF] + Array(repeating: 65, count: 8_190) + [0], true)),
    (
      "不正バイト10個の後、元の位置 8195 の NUL",
      (Array(repeating: 0xFF, count: 10) + Array(repeating: 65, count: 8_185) + [0], false)
    ),
    ("サイズ閾値超過", (Array(repeating: 65, count: 100) + [0xFF, 0x0A], false)),
  ]

  @Test(
    "不正 UTF-8 は NUL の位置を判定し、現在のファイルと同じ観測・確認・本文を返す",
    arguments: invalidCases.map(\.0), [FileOpenConfirmation.notConfirmed, .confirmed])
  func invalidUTF8MatchesFileContentReader(
    name: String, confirmation: FileOpenConfirmation
  ) throws {
    let testCase = try #require(Self.invalidCases.first { $0.0 == name })
    let bytes = testCase.1.bytes
    let expected = try readThroughFileContentReader(bytes, confirmation: confirmation)
    let stdout = String(decoding: bytes, as: UTF8.self)
    let actual = GitBlobContent.classify(
      stdout: stdout, byteCount: bytes.count, objectID: Self.blobID(of: bytes),
      thresholds: Self.thresholds, confirmation: confirmation)

    #expect(actual == expected)
    if testCase.1.isBinary {
      #expect(actual.observation == .binary(byteCount: bytes.count))
      #expect(actual.text == nil)
    } else if bytes.count > Self.thresholds.maximumByteCount, confirmation == .notConfirmed {
      #expect(actual.observation == .text(byteCount: bytes.count, lineCount: nil))
      #expect(
        actual.decision.confirmationReasons?.elements
          == [.byteCount(actual: bytes.count, maximum: Self.thresholds.maximumByteCount)])
      #expect(actual.text == nil)
    } else {
      #expect(actual.observation == .undecodable(byteCount: bytes.count, lineCount: 1))
      var reasons: [FileOpenConfirmationReason] = [.undecodable]
      if bytes.count > Self.thresholds.maximumByteCount {
        reasons.append(.byteCount(actual: bytes.count, maximum: Self.thresholds.maximumByteCount))
      }
      #expect(actual.decision.confirmationReasons?.elements == reasons)
      if confirmation == .confirmed {
        let text = try #require(actual.text)
        #expect(text.content == stdout)
        #expect(text.truncatedAtByteCount == nil)
      } else {
        #expect(actual.text == nil)
      }
    }
  }

  @Test(
    "置換文字で NUL の元の位置が決まらない過去版は binary に留める",
    arguments: [FileOpenConfirmation.notConfirmed, .confirmed])
  func keepsAmbiguousNULPositionBinary(confirmation: FileOpenConfirmation) throws {
    let prefix = Array(String(repeating: "\u{FFFD}", count: 10).utf8) + [0xFF]
    let bytes = prefix + Array(repeating: UInt8(65), count: 8_192 - prefix.count) + [0]
    let thresholds = FileViewThresholds(maximumByteCount: 10_000, maximumLineCount: 3)
    let url = FileManager.default.temporaryDirectory
      .appending(path: "awt-blob-\(UUID().uuidString)")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let current = try FileContentReader().read(
      url: url, thresholds: thresholds, confirmation: confirmation)
    let historical = GitBlobContent.classify(
      stdout: String(decoding: bytes, as: UTF8.self), byteCount: bytes.count,
      objectID: Self.blobID(of: bytes), thresholds: thresholds, confirmation: confirmation)

    #expect(current.observation == .undecodable(byteCount: bytes.count, lineCount: 1))
    #expect(historical.observation == .binary(byteCount: bytes.count))
    #expect(historical.text == nil)
  }

  @Test(
    "U+FFFD を含まない未知の OID 桁数による不一致は binary に留める",
    arguments: [FileOpenConfirmation.notConfirmed, .confirmed])
  func keepsUnexplainedObjectIDMismatchBinary(confirmation: FileOpenConfirmation) {
    let stdout = "plain\n"
    let actual = GitBlobContent.classify(
      stdout: stdout, byteCount: stdout.utf8.count, objectID: String(repeating: "a", count: 41),
      thresholds: Self.thresholds, confirmation: confirmation)
    #expect(actual.observation == .binary(byteCount: stdout.utf8.count))
    #expect(actual.text == nil)
  }

  @Test("SHA-256 の repository の OID でも内容の同一性を確かめられる")
  func verifiesSHA256ObjectID() throws {
    let bytes = Array("sha256\n".utf8)
    let header = Array("blob \(bytes.count)\0".utf8)
    let objectID = SHA256.hash(data: header + bytes).map { String(format: "%02x", $0) }.joined()

    let actual = GitBlobContent.classify(
      stdout: String(decoding: bytes, as: UTF8.self), byteCount: bytes.count, objectID: objectID,
      thresholds: Self.thresholds, confirmation: .notConfirmed)

    #expect(actual.text?.content == "sha256\n")
  }

  private func readThroughFileContentReader(
    _ bytes: [UInt8], confirmation: FileOpenConfirmation
  ) throws -> FileContentReadResult {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "awt-blob-\(UUID().uuidString)")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try FileContentReader().read(
      url: url, thresholds: Self.thresholds, confirmation: confirmation)
  }

  private static func blobID(of bytes: [UInt8]) -> String {
    let header = Array("blob \(bytes.count)\0".utf8)
    return Insecure.SHA1.hash(data: header + bytes).map { String(format: "%02x", $0) }.joined()
  }
}
