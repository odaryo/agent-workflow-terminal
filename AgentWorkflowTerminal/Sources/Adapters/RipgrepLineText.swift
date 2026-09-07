import Foundation
import TerminalCore

public enum RipgrepLineText {
  /// rg の行バイト列と、その先頭からのバイトオフセットで表されたマッチ範囲を、
  /// 表示用の行テキストとその上の位置へ変換する。
  ///
  /// rg 15.2.0 の `--json` は `--max-columns` / `--max-columns-preview` を無視し、
  /// 長い行をそのまま出す (実測: `--max-columns 10` でも 11 バイトの行が丸ごと来る)。
  /// あの2つは人間向け printer 専用の option なので、表示幅の上限はここで適用する。
  public static func line(
    fromBytes bytes: [UInt8],
    submatchByteRanges: [Range<Int>],
    maximumColumns: Int = WorktreeSearchLimits.maximumDisplayedColumns
  ) -> WorktreeSearchLine? {
    var trimmed = bytes[...]
    if trimmed.last == 0x0A { trimmed = trimmed.dropLast() }
    if trimmed.last == 0x0D { trimmed = trimmed.dropLast() }
    let content = Array(trimmed)

    let full = String(decoding: content, as: UTF8.self)
    let isTruncated = full.count > maximumColumns
    let text = isTruncated ? String(full.prefix(maximumColumns)) : full
    let displayUTF8Count = text.utf8.count

    // 不正バイトは U+FFFD (3 バイト) へ置換されるので、生バイトのオフセットと
    // デコード後のオフセットは一致しない。全体が妥当な UTF-8 のときだけ恒等写像になる。
    let isValidUTF8 = full.utf8.count == content.count
    func decodedOffset(_ offset: Int) -> Int {
      guard !isValidUTF8 else { return offset }
      return String(decoding: content[..<offset], as: UTF8.self).utf8.count
    }

    var matches: [Range<String.Index>] = []
    for range in submatchByteRanges {
      guard range.lowerBound >= 0, range.lowerBound <= content.count else { continue }
      // 落とした行末へ食い込む範囲は弾かずに切り詰める。`.*` 系は CRLF ファイルの行末 CR まで
      // 一致するため (実測 15.2.0: `hello world\r\n` の 13 バイトに対し end = 12)、
      // 弾くと CRLF のファイルではハイライトが常に消える。
      let lower = decodedOffset(range.lowerBound)
      let upper = decodedOffset(min(range.upperBound, content.count))
      // 表示幅で落とした側にあるマッチは、表示している文字列の上に位置を持たない。
      guard lower <= upper, upper <= displayUTF8Count else { continue }
      guard let start = index(in: text, utf8Offset: lower),
        let end = index(in: text, utf8Offset: upper)
      else { continue }
      matches.append(start..<end)
    }

    return WorktreeSearchLine(text: text, matches: matches, isTruncated: isTruncated)
  }

  /// UTF-8 オフセットが grapheme cluster の途中を指す場合は `nil`。範囲を落として
  /// 行そのものは残す — 一致した行を落とすと「一致が無かった」に化ける (§12.3)。
  private static func index(in text: String, utf8Offset: Int) -> String.Index? {
    guard
      let utf8Index = text.utf8.index(
        text.utf8.startIndex, offsetBy: utf8Offset, limitedBy: text.utf8.endIndex)
    else { return nil }
    return utf8Index.samePosition(in: text)
  }
}
