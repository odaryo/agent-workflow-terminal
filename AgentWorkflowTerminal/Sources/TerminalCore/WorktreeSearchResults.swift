import Foundation

public struct WorktreeSearchLine: Sendable, Hashable {
  public let text: String
  /// `text` 上の位置。ripgrep が返すバイトオフセットの変換は Adapters の責務で、
  /// ここへ来る時点で行テキストの位置になっている。
  public let matches: [Range<String.Index>]
  /// §8.2 の表示幅上限で末尾を落とした行。落とした側にあるマッチは `matches` に含まれない。
  public let isTruncated: Bool

  /// 行区切りの LF だけを拒む。孤立した CR はファイルの中身としてあり得るので、
  /// 落とすとその行の検索結果ごと失う。`\r\n` の除去は行を切り出す側の責務。
  public init?(text: String, matches: [Range<String.Index>], isTruncated: Bool) {
    guard !text.unicodeScalars.contains(where: { $0.value == 0x0A }) else { return nil }
    guard
      matches.allSatisfy({ range in
        range.lowerBound >= text.startIndex && range.upperBound <= text.endIndex
      })
    else { return nil }
    self.text = text
    self.matches = matches
    self.isTruncated = isTruncated
  }
}

/// Code Viewer で開く対象。`lineNumber` は 1 始まりで、`nil` は行を特定していないことを表す。
public struct WorktreeSearchOpenTarget: Sendable, Hashable {
  public let path: WorktreeRelativePath
  public let lineNumber: Int?

  public init(path: WorktreeRelativePath, lineNumber: Int?) {
    self.path = path
    self.lineNumber = lineNumber
  }
}

public struct WorktreeSearchMatch: Sendable, Hashable, Identifiable {
  public let path: WorktreeRelativePath
  /// 1 始まり。
  public let lineNumber: Int
  public let line: WorktreeSearchLine

  /// ripgrep は1つの行につき1つの `match` イベントしか出さないため、パスと行番号で一意。
  public var id: String { path.value + "\u{0000}" + String(lineNumber) }

  public var openTarget: WorktreeSearchOpenTarget {
    WorktreeSearchOpenTarget(path: path, lineNumber: lineNumber)
  }

  public init?(path: WorktreeRelativePath, lineNumber: Int, line: WorktreeSearchLine) {
    guard lineNumber >= 1 else { return nil }
    self.path = path
    self.lineNumber = lineNumber
    self.line = line
  }
}

public struct WorktreeFileNameMatch: Sendable, Hashable, Identifiable {
  public let path: WorktreeRelativePath
  /// `path.value` 上の一致範囲。
  public let range: Range<String.Index>

  public var id: String { path.value }

  public var openTarget: WorktreeSearchOpenTarget {
    WorktreeSearchOpenTarget(path: path, lineNumber: nil)
  }
}

public enum WorktreeFileNameSearch {
  /// §8.2 の既定: `rg --files` の出力に対する、大文字小文字を無視した部分一致。
  public static func matches(
    term: String,
    in paths: [WorktreeRelativePath]
  ) -> [WorktreeFileNameMatch] {
    guard term.contains(where: { !$0.isWhitespace }) else { return [] }
    return paths.compactMap { path in
      guard let range = path.value.range(of: term, options: [.caseInsensitive]) else { return nil }
      return WorktreeFileNameMatch(path: path, range: range)
    }
  }
}

public struct WorktreeSearchTruncation: Sendable, Hashable {
  /// §8.2 の全体上限に達したため、以降の結果を捨てた。
  public let reachedResultLimit: Bool
  /// ripgrep の `--max-count` に達したファイル。表示している結果に含まれるものだけを載せる。
  public let filesReachingPerFileLimit: [WorktreeRelativePath]

  public var isTruncated: Bool { reachedResultLimit || !filesReachingPerFileLimit.isEmpty }

  public static let none = Self(reachedResultLimit: false, filesReachingPerFileLimit: [])
}

public struct WorktreeSearchOutcome: Sendable, Hashable {
  public let matches: [WorktreeSearchMatch]
  public let truncation: WorktreeSearchTruncation

  /// 全体上限で表示から外れたファイルについては、ファイル単位の打ち切りを報告しない。
  /// 1件も見せていないファイルの「一部しか出していない」は、欠けているものの説明を
  /// 二重にするだけで、何が欠けたかを伝えない (§12.3)。
  public static func applyingResultLimit(
    to matches: [WorktreeSearchMatch],
    filesReachingPerFileLimit: [WorktreeRelativePath],
    limit: Int = WorktreeSearchLimits.maximumResultCount
  ) -> Self {
    let kept = Array(matches.prefix(max(limit, 0)))
    let keptPaths = Set(kept.map(\.path))
    return Self(
      matches: kept,
      truncation: WorktreeSearchTruncation(
        reachedResultLimit: matches.count > kept.count,
        filesReachingPerFileLimit: filesReachingPerFileLimit.filter(keptPaths.contains)))
  }
}
