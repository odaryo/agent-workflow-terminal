import CryptoKit
import Foundation
import TerminalCore

/// `ProcessRunner` の stdout では不正 UTF-8 が U+FFFD に置換済みで、元のバイト位置は失われる。
/// OID が一致した場合だけ元のバイト列として扱い、不一致では NUL の元の位置を範囲で判定する。
/// 先頭 8 KiB 内か決められない場合は binary に留める (設計書 §7.3)。
enum GitBlobContent {
  /// `byteCount` は `ls-tree` が返した blob の実サイズ。OID が一致しなかった場合、stdout の
  /// バイト数は置換で変わっているので、こちらを使う。
  static func classify(
    stdout: String,
    byteCount: Int,
    objectID: String,
    thresholds: FileViewThresholds,
    confirmation: FileOpenConfirmation
  ) -> FileContentReadResult {
    let data = Data(stdout.utf8)
    guard data.count == byteCount, blobID(of: data, matching: objectID) == objectID else {
      return classifyReplaced(
        stdout: stdout, data: data, byteCount: byteCount, thresholds: thresholds,
        confirmation: confirmation)
    }
    let sampleCount = min(byteCount, BinaryFileDetection.sampleByteCount)
    if let sample = BinaryFileSample(
      bytes: Array(data.prefix(sampleCount)), fileByteCount: byteCount),
      BinaryFileDetection.isBinary(sample: sample)
    {
      return result(.binary(byteCount: byteCount), text: nil, thresholds: thresholds)
    }
    if byteCount > thresholds.maximumByteCount, confirmation == .notConfirmed {
      return result(.text(byteCount: byteCount, lineCount: nil), text: nil, thresholds: thresholds)
    }
    let limit = min(byteCount, thresholds.absoluteMaximumByteCount)
    let isTruncated = limit < byteCount
    guard
      let decoded = FileContentReader.decodeUTF8(
        Data(data.prefix(limit)), droppingIncompleteTail: isTruncated)
    else {
      return result(.binary(byteCount: byteCount), text: nil, thresholds: thresholds)
    }
    let observation = FileViewObservation.text(
      byteCount: byteCount,
      lineCount: isTruncated ? nil : FileContentReader.lineCount(of: data))
    let decision = FileOpenDecision.decide(observation: observation, thresholds: thresholds)
    let text = FileContentText(
      content: decoded.text, truncatedAtByteCount: isTruncated ? decoded.byteCount : nil)
    return FileContentReadResult(
      observation: observation, decision: decision,
      text: decision == .display || confirmation == .confirmed ? text : nil)
  }

  private static func classifyReplaced(
    stdout: String,
    data: Data,
    byteCount: Int,
    thresholds: FileViewThresholds,
    confirmation: FileOpenConfirmation
  ) -> FileContentReadResult {
    if isBinaryAfterReplacement(data) {
      return result(.binary(byteCount: byteCount), text: nil, thresholds: thresholds)
    }
    if byteCount > thresholds.maximumByteCount, confirmation == .notConfirmed {
      return result(.text(byteCount: byteCount, lineCount: nil), text: nil, thresholds: thresholds)
    }
    return result(
      .undecodable(byteCount: byteCount, lineCount: FileContentReader.lineCount(of: data)),
      text: confirmation == .confirmed
        ? FileContentText(content: stdout, truncatedAtByteCount: nil) : nil,
      thresholds: thresholds)
  }

  private static func isBinaryAfterReplacement(_ data: Data) -> Bool {
    guard data.range(of: Data([0xEF, 0xBF, 0xBD])) != nil else { return true }
    guard let nulPosition = data.firstIndex(of: 0) else { return false }
    if nulPosition < BinaryFileDetection.sampleByteCount { return true }
    // 正しい U+FFFD と置換された U+FFFD は区別できず、元の NUL 位置を一点には戻せない (§7.3)。
    let replacementCount = String(decoding: data[..<nulPosition], as: UTF8.self)
      .unicodeScalars.reduce(into: 0) { count, scalar in
        if scalar.value == 0xFFFD { count += 1 }
      }
    return nulPosition - 2 * replacementCount < BinaryFileDetection.sampleByteCount
  }

  /// hash 算法は OID の桁数で選ぶ (SHA-1 は 40 桁、SHA-256 は 64 桁)。
  private static func blobID(of data: Data, matching objectID: String) -> String? {
    var input = Data("blob \(data.count)\0".utf8)
    input.append(data)
    switch objectID.utf8.count {
    case 40: return hex(Insecure.SHA1.hash(data: input))
    case 64: return hex(SHA256.hash(data: input))
    default: return nil
    }
  }

  private static func hex(_ digest: some Sequence<UInt8>) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func result(
    _ observation: FileViewObservation, text: FileContentText?, thresholds: FileViewThresholds
  ) -> FileContentReadResult {
    FileContentReadResult(
      observation: observation,
      decision: FileOpenDecision.decide(observation: observation, thresholds: thresholds),
      text: text)
  }
}
