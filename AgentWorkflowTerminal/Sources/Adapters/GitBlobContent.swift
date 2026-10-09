import CryptoKit
import Foundation
import TerminalCore

/// 過去版の本文に、現在のファイル (`FileContentReader`) と同じ §7.2 の判定を当てる。
///
/// `ProcessRunner` は stdout を非失敗デコード済みの `String` でしか返さないため、不正 UTF-8 の
/// バイトは U+FFFD に置き換わっていて、そのままでは「不正 UTF-8 はバイナリ」の判定も、先頭
/// 8 KiB の位置での NUL 判定もできない。そこで復号結果を UTF-8 に戻したバイト列から blob の
/// OID を計算し、git が返した OID と一致したときだけ「元のバイト列そのもの」として扱う。
/// 一致しなければ置換が起きた = 元は不正 UTF-8 を含んでいたので、バイナリと判定する。
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
      return result(.binary(byteCount: byteCount), text: nil, thresholds: thresholds)
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
