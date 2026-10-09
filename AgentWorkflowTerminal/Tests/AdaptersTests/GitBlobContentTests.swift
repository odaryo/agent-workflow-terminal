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

  @Test("不正 UTF-8 を含む小さい内容は、現在のファイルと同じくバイナリになる")
  func invalidUTF8IsBinary() throws {
    let bytes: [UInt8] = Array("ok ".utf8) + [0xFF, 0xFE] + Array("\n".utf8)
    let expected = try readThroughFileContentReader(bytes, confirmation: .notConfirmed)

    let actual = GitBlobContent.classify(
      stdout: String(decoding: bytes, as: UTF8.self), byteCount: bytes.count,
      objectID: Self.blobID(of: bytes),
      thresholds: Self.thresholds, confirmation: .notConfirmed)

    #expect(actual == expected)
    #expect(actual.observation == .binary(byteCount: bytes.count))
  }

  /// stdout は非失敗デコード済みの String でしか受け取れず、不正バイトの位置と長さは失われる。
  /// 現在のファイルなら「サイズ超過の確認 → 開くとバイナリ」になる内容を、過去版は確認前から
  /// バイナリと判定する (この1点だけが現在のファイルと異なる)。
  @Test("不正 UTF-8 を含む大きい内容は、確認前からバイナリになる")
  func invalidUTF8LargeIsBinaryBeforeConfirmation() {
    let bytes = Array(repeating: UInt8(ascii: "a"), count: 100) + [0xFF]

    let actual = GitBlobContent.classify(
      stdout: String(decoding: bytes, as: UTF8.self), byteCount: bytes.count,
      objectID: Self.blobID(of: bytes),
      thresholds: Self.thresholds, confirmation: .notConfirmed)

    #expect(actual.observation == .binary(byteCount: bytes.count))
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
