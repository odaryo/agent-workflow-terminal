public enum UnifiedDiffLineKind: Sendable, Equatable, Hashable {
  case context
  case added
  case removed
}

/// 行番号は 1 始まり。追加行は old 側に、削除行は new 側に存在しないので、その側は `nil`。
public struct UnifiedDiffLine: Sendable, Equatable, Hashable {
  public let kind: UnifiedDiffLineKind
  public let oldLineNumber: Int?
  public let newLineNumber: Int?
  /// 先頭の ` ` / `+` / `-` を除いた本文。
  public let text: String
  /// 直後に `\ No newline at end of file` が付いていた行。
  public let isMissingTrailingNewline: Bool

  public init(
    kind: UnifiedDiffLineKind,
    oldLineNumber: Int?,
    newLineNumber: Int?,
    text: String,
    isMissingTrailingNewline: Bool = false
  ) {
    self.kind = kind
    self.oldLineNumber = oldLineNumber
    self.newLineNumber = newLineNumber
    self.text = text
    self.isMissingTrailingNewline = isMissingTrailingNewline
  }
}

public struct UnifiedDiffHunk: Sendable, Equatable, Hashable {
  public let oldStart: Int
  public let oldCount: Int
  public let newStart: Int
  public let newCount: Int
  /// `@@ ... @@` の後ろに git が付ける文脈 (関数名等)。無ければ空文字。
  public let section: String
  public let lines: [UnifiedDiffLine]

  public init(
    oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String,
    lines: [UnifiedDiffLine]
  ) {
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
    self.section = section
    self.lines = lines
  }
}

public enum UnifiedDiffChangeKind: Sendable, Equatable, Hashable {
  case added
  case deleted
  case modified
  /// `similarity` は git の `similarity index` の百分率。出力に無ければ `nil`。
  case renamed(from: String, similarity: Int?)
  case copied(from: String, similarity: Int?)
  /// マージ／rebase 中の競合 (§9.1.3)。`DU` を `modified` と呼ぶような丸めをしない (§12.3)。
  case conflicted
}

/// `git status --porcelain=v2` の `u` レコードが持つ競合の状態。
public struct UnifiedDiffConflict: Sendable, Equatable, Hashable {
  /// `u` レコードの XY (例: `UU` / `AA` / `DU`)。**組で1つの競合の種類**を表すので、
  /// index / worktree を別々に読まないこと — `displayedStatus` は競合値に対しては意味を持たない
  /// (`UA` に対して theirs 側の `A` を返す)。
  ///
  /// stage の mode は持たない。そのため競合中の submodule と型競合を通常のファイル競合と
  /// 区別できない (Issue #305)。
  public let status: WorktreeTrackedFileStatus
  /// stage 1/2/3 の OID。実体の無い stage は `nil` — git は全 0 の OID で表すが、その値を
  /// そのまま持つと「OID がある」と読めてしまう。
  public let baseObject: String?
  public let ourObject: String?
  public let theirObject: String?

  public init(
    status: WorktreeTrackedFileStatus,
    baseObject: String?,
    ourObject: String?,
    theirObject: String?
  ) {
    self.status = status
    self.baseObject = baseObject
    self.ourObject = ourObject
    self.theirObject = theirObject
  }
}

public enum UnifiedDiffUnreadableReason: Sendable, Equatable, Hashable {
  case binary(byteCount: Int)
  case tooLarge(byteCount: Int)
  case notReadable
}

public enum UnifiedDiffContent: Sendable, Equatable, Hashable {
  case hunks([UnifiedDiffHunk])
  /// git が `Binary files ... differ` と言った状態。binary Diff の表示方法は §25 で未確定なので、
  /// 中身を推測で作らない。
  case binary
  /// mode 変更や rename だけで hunk が無い状態。
  case noContentChange
  /// untracked ファイルの中身を読めず、全行追加へ合成できなかった状態。「変更なし」とも
  /// 「binary」とも言えないので独立させる (§12.3)。
  case unreadable(UnifiedDiffUnreadableReason)
  /// 競合中のため P2 では本文 (combined diff) を出さないと決めた状態 (§9.1.3)。読めなかった
  /// `unreadable` とは意味が違うので分ける。
  case conflicted(UnifiedDiffConflict)
}

public struct UnifiedDiffFile: Sendable, Equatable, Hashable {
  /// 新規追加では `nil` (`--- /dev/null`)。
  public let oldPath: String?
  /// 削除では `nil` (`+++ /dev/null`)。
  public let newPath: String?
  /// 一覧のキーと表示に使う。`newPath ?? oldPath`。
  public let path: String
  public let changeKind: UnifiedDiffChangeKind
  /// git の 6 桁表現をそのまま保つ。`160000` は gitlink。
  public let oldMode: String?
  public let newMode: String?
  /// `index <old>..<new>` の OID。桁数は git の省略形のまま。binary のように差分行を持たない
  /// ファイルでは、これだけが内容の同一性を表す。
  public let oldObject: String?
  public let newObject: String?
  public let content: UnifiedDiffContent

  public init(
    oldPath: String?,
    newPath: String?,
    changeKind: UnifiedDiffChangeKind,
    oldMode: String? = nil,
    newMode: String? = nil,
    oldObject: String? = nil,
    newObject: String? = nil,
    content: UnifiedDiffContent
  ) {
    self.oldPath = oldPath
    self.newPath = newPath
    path = newPath ?? oldPath ?? ""
    self.changeKind = changeKind
    self.oldMode = oldMode
    self.newMode = newMode
    self.oldObject = oldObject
    self.newObject = newObject
    self.content = content
  }

  /// submodule の差分表示方法は §25 で未確定。gitlink であることだけを上位へ伝える。
  public var isSubmodule: Bool { oldMode == "160000" || newMode == "160000" }

  public var hunks: [UnifiedDiffHunk] {
    if case .hunks(let hunks) = content { return hunks }
    return []
  }
}

public enum UntrackedFileDiff {
  /// §9.1.3: untracked は新規ファイルとして全行追加で合成する。git の patch と同じ形になるよう、
  /// 末尾の改行が無い場合は最終行に `isMissingTrailingNewline` を立てる。
  public static func addedFile(path: String, content: String) -> UnifiedDiffFile {
    let texts = lines(of: content)
    guard !texts.isEmpty else {
      // git も空ファイルには hunk を出さない。
      return UnifiedDiffFile(
        oldPath: nil, newPath: path, changeKind: .added, content: .noContentChange)
    }
    let missingTrailingNewline = content.last != "\n"
    let lines = texts.enumerated().map { index, text in
      UnifiedDiffLine(
        kind: .added,
        oldLineNumber: nil,
        newLineNumber: index + 1,
        text: text,
        isMissingTrailingNewline: missingTrailingNewline && index == texts.count - 1)
    }
    return UnifiedDiffFile(
      oldPath: nil,
      newPath: path,
      changeKind: .added,
      content: .hunks([
        UnifiedDiffHunk(
          oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, section: "", lines: lines)
      ]))
  }

  public static func fileWithoutContent(
    path: String, reason: UnifiedDiffUnreadableReason
  ) -> UnifiedDiffFile {
    UnifiedDiffFile(
      oldPath: nil, newPath: path, changeKind: .added, content: .unreadable(reason))
  }

  private static func lines(of content: String) -> [String] {
    guard !content.isEmpty else { return [] }
    var texts = content.components(separatedBy: "\n")
    if texts.last?.isEmpty == true { texts.removeLast() }
    return texts
  }
}

public enum ConflictedFileDiff {
  /// §9.1.3: 競合中のファイルは status の `u` レコードだけから作る。競合には「変更前」の
  /// パスという概念が無いので、両側とも同じパスにする。
  public static func file(path: String, conflict: UnifiedDiffConflict) -> UnifiedDiffFile {
    UnifiedDiffFile(
      oldPath: path, newPath: path, changeKind: .conflicted, content: .conflicted(conflict))
  }
}

public enum UnifiedDiffCanonicalText {
  /// snapshot 生成時の観測値 (fingerprint) を作るための決定的な直列化。表示には使わない。
  ///
  /// 差分行を持たないファイル (binary・mode 変更のみ) の同一性は `index` の OID が担う。
  /// untracked で中身を読めなかったファイルだけは OID が無く、サイズしか比べられないため、
  /// 同じサイズのままの書き換えを検知できない。
  ///
  /// 競合中のファイルも同じ限界を持つ: 前像に入るのは XY と stage 1/2/3 の OID だけなので、
  /// stage を動かさない作業ツリー上の変化 — 競合マーカーの手直しも、ファイルごと削除して
  /// `u` レコードの `mW` が `000000` になることも — 検知できない (Issue #306)。
  public static func text(of file: UnifiedDiffFile) -> String {
    var parts: [String] = [
      file.oldPath ?? "", file.newPath ?? "", encode(file.changeKind),
      file.oldMode ?? "", file.newMode ?? "", file.oldObject ?? "", file.newObject ?? "",
    ]
    switch file.content {
    case .binary: parts.append("binary")
    case .noContentChange: parts.append("no-content-change")
    case .unreadable(let reason): parts.append("unreadable:" + encode(reason))
    case .conflicted(let conflict): parts.append("conflicted:" + encode(conflict))
    case .hunks(let hunks):
      for hunk in hunks {
        parts.append("@@\(hunk.oldStart),\(hunk.oldCount) \(hunk.newStart),\(hunk.newCount)")
        for line in hunk.lines {
          parts.append(
            "\(line.kind):\(line.oldLineNumber ?? -1):\(line.newLineNumber ?? -1)"
              + ":\(line.isMissingTrailingNewline ? 1 : 0):\(line.text)")
        }
      }
    }
    // 本文に現れない区切りとして US を使う (`GitLog.format` と同じ理由)。
    return parts.joined(separator: "\u{1F}")
  }

  private static func encode(_ kind: UnifiedDiffChangeKind) -> String {
    switch kind {
    case .added: "added"
    case .deleted: "deleted"
    case .modified: "modified"
    case .renamed(let from, let similarity): "renamed:\(from):\(similarity ?? -1)"
    case .copied(let from, let similarity): "copied:\(from):\(similarity ?? -1)"
    case .conflicted: "conflicted"
    }
  }

  private static func encode(_ conflict: UnifiedDiffConflict) -> String {
    [
      encode(conflict.status.index), encode(conflict.status.worktree),
      conflict.baseObject ?? "", conflict.ourObject ?? "", conflict.theirObject ?? "",
    ].joined(separator: ":")
  }

  private static func encode(_ status: WorktreeGitFileStatus) -> String {
    switch status {
    case .unchanged: "unchanged"
    case .modified: "modified"
    case .typeChanged: "type-changed"
    case .added: "added"
    case .deleted: "deleted"
    case .renamed: "renamed"
    case .copied: "copied"
    case .unmerged: "unmerged"
    }
  }

  private static func encode(_ reason: UnifiedDiffUnreadableReason) -> String {
    switch reason {
    case .binary(let byteCount): "binary:\(byteCount)"
    case .tooLarge(let byteCount): "too-large:\(byteCount)"
    case .notReadable: "not-readable"
    }
  }
}
