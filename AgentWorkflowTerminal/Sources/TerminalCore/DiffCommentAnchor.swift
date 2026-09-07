import CryptoKit
import Foundation

/// 1 始まりの閉区間。`start > end` と 0 以下の行番号を初期化子で弾き、空・逆転の範囲を
/// 値として作れないようにする (設計書 §9.2)。
public struct DiffLineRange: Sendable, Equatable, Hashable {
  public let start: Int
  public let end: Int

  public init?(start: Int, end: Int) {
    guard start >= 1, end >= start else { return nil }
    self.start = start
    self.end = end
  }

  public init?(line: Int) {
    self.init(start: line, end: line)
  }

  public var lineNumbers: ClosedRange<Int> { start...end }
  public var count: Int { end - start + 1 }
}

/// anchor が抱える1行。`isMissingTrailingNewline` は `UnifiedDiffLine` の同名フィールドと同義で、
/// ハッシュの前像に入るため表示上の飾りではない (`DiffCommentAnchor.hashPreimage`)。
public struct DiffAnchoredLine: Sendable, Equatable, Hashable {
  public let lineNumber: Int
  /// 先頭の ` ` / `+` / `-` を除いた本文 (`UnifiedDiffLine.text`)。
  public let text: String
  public let isMissingTrailingNewline: Bool

  public init(lineNumber: Int, text: String, isMissingTrailingNewline: Bool) {
    self.lineNumber = lineNumber
    self.text = text
    self.isMissingTrailingNewline = isMissingTrailingNewline
  }
}

public enum DiffCommentAnchorCorruption: Sendable, Equatable, Hashable {
  /// 同じ snapshot ID を名乗る snapshot に、その出所・パス・側・行範囲が無い。
  case linesNotFound
  case textHashMismatch
}

/// `differentSnapshot` を `corrupted` へ丸めないのは、§9.3 が新しい snapshot への追従を
/// 禁じているためで、「別 snapshot に対して聞かれた」は記録の破損ではなく質問の誤りである
/// (判定できないものを丸めない: 設計書 §12.3 と同じ扱い)。
public enum DiffCommentAnchorVerification: Sendable, Equatable, Hashable {
  case intact
  case corrupted(DiffCommentAnchorCorruption)
  case differentSnapshot(anchor: DiffSnapshotID, snapshot: DiffSnapshotID)
}

/// 設計書 §9.2 の6要素 (snapshot ID／出所／パス／側／行範囲／対象行のテキストハッシュ)。
///
/// 初期化子を module 内に閉じているのは、**snapshot 上に実在する行からしか作れない**という
/// 要求を型で守るため。生成経路は `DiffSnapshot.commentAnchor(origin:path:side:lines:)` だけ。
///
/// - Important: この型から「新しい snapshot での対応行」を求める API は用意しない (§9.3)。
///   ハッシュは記録が壊れていないことの検証と、送信文面へ元コードを添えるためだけにある。
public struct DiffCommentAnchor: Sendable, Equatable, Hashable {
  public let snapshotID: DiffSnapshotID
  public let origin: DiffChangeOrigin
  public let path: String
  public let side: DiffLineSide
  public let lines: DiffLineRange
  /// `lines` の行番号昇順。`lines.count` と同数で、欠けた行があれば anchor を作らない。
  public let anchoredLines: [DiffAnchoredLine]
  /// `textHash(of: anchoredLines)`。前像の定義は `hashPreimage(of:)` を参照。
  public let textHash: String

  init(
    snapshotID: DiffSnapshotID,
    origin: DiffChangeOrigin,
    path: String,
    side: DiffLineSide,
    lines: DiffLineRange,
    anchoredLines: [DiffAnchoredLine]
  ) {
    self.snapshotID = snapshotID
    self.origin = origin
    self.path = path
    self.side = side
    self.lines = lines
    self.anchoredLines = anchoredLines
    textHash = Self.textHash(of: anchoredLines)
  }

  /// 元コードとして送信文面へ載せる形 (§9.2)。行は LF で繋ぎ、**末尾には何も足さない**。
  /// 最終行の `isMissingTrailingNewline` はここでは表現しない (文面側が必要なら別に添える)。
  public var anchoredText: String {
    anchoredLines.map(\.text).joined(separator: "\n")
  }

  /// ハッシュの前像。固定文字列 `awt-diff-line-hash-v1` に続けて、行番号の昇順で1行ずつ
  /// `":" + <text の UTF-8 バイト数(10進)> + ":" + text + ":" + ("1" | "0")` を連結する。
  /// 末尾の `1` / `0` は `isMissingTrailingNewline`。
  ///
  /// 行の区切りに改行や区切り文字を使わず**長さを前置する**のは、区切り文字が本文に現れないことへ
  /// 依存しないため。diff の行本文は LF を含まないが、C0 制御文字や US (U+001F) は含み得る。
  /// 前像そのものに末尾の改行は付けない。
  ///
  /// - Note: 行番号は前像に入れない。行番号は anchor の独立したフィールドであり、
  ///   ここが表すのは設計書が言う「対象行のテキスト」ハッシュだけ。
  static func hashPreimage(of lines: [DiffAnchoredLine]) -> String {
    var preimage = "awt-diff-line-hash-v1"
    for line in lines.sorted(by: { $0.lineNumber < $1.lineNumber }) {
      preimage += ":\(line.text.utf8.count):\(line.text):\(line.isMissingTrailingNewline ? 1 : 0)"
    }
    return preimage
  }

  /// SHA-256 の16進小文字。CryptoKit を使うのは、macOS と iOS simulator の両方 (この package の
  /// platform はその2つ) で追加依存なく同じ実装が使えるため。
  static func textHash(of lines: [DiffAnchoredLine]) -> String {
    SHA256.hash(data: Data(hashPreimage(of: lines).utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

extension DiffSnapshot {
  /// 実在しない出所・パス・行番号からは `nil`。範囲内の行が1つでも欠けていれば作らない。
  public func commentAnchor(
    origin: DiffChangeOrigin,
    path: String,
    side: DiffLineSide,
    lines: DiffLineRange
  ) -> DiffCommentAnchor? {
    guard let anchored = anchoredLines(origin: origin, path: path, side: side, lines: lines) else {
      return nil
    }
    return DiffCommentAnchor(
      snapshotID: id, origin: origin, path: path, side: side, lines: lines,
      anchoredLines: anchored)
  }

  /// 別 snapshot の anchor を渡されたら、行を探しにいかずに `differentSnapshot` を返す (§9.3)。
  public func verify(_ anchor: DiffCommentAnchor) -> DiffCommentAnchorVerification {
    guard anchor.snapshotID == id else {
      return .differentSnapshot(anchor: anchor.snapshotID, snapshot: id)
    }
    guard
      let anchored = anchoredLines(
        origin: anchor.origin, path: anchor.path, side: anchor.side, lines: anchor.lines)
    else {
      return .corrupted(.linesNotFound)
    }
    guard DiffCommentAnchor.textHash(of: anchored) == anchor.textHash else {
      return .corrupted(.textHashMismatch)
    }
    return .intact
  }

  private func anchoredLines(
    origin: DiffChangeOrigin,
    path: String,
    side: DiffLineSide,
    lines: DiffLineRange
  ) -> [DiffAnchoredLine]? {
    guard let file = file(origin: origin, path: path) else { return nil }
    var found: [Int: DiffAnchoredLine] = [:]
    for hunk in file.hunks {
      for line in hunk.lines {
        let number = side == .old ? line.oldLineNumber : line.newLineNumber
        guard let number, lines.lineNumbers.contains(number) else { continue }
        found[number] = DiffAnchoredLine(
          lineNumber: number, text: line.text,
          isMissingTrailingNewline: line.isMissingTrailingNewline)
      }
    }
    guard found.count == lines.count else { return nil }
    return lines.lineNumbers.compactMap { found[$0] }
  }
}
