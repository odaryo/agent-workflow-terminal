import Foundation
import TerminalCore

public enum UnifiedDiffParseError: Error, Sendable, Equatable {
  case unexpectedLine(String)
  /// `diff --git a/x b/y` の path は空白を含むと切れ目が一意に決まらない。`---` / `+++` も
  /// `rename from` / `rename to` も無い場合だけここへ来る。
  case ambiguousHeaderPaths(String)
  case invalidHunkHeader(String)
  case truncatedHunk(remainingOld: Int, remainingNew: Int)
}

public struct UnifiedDiffParseFailure: Error, Sendable, Equatable {
  /// 1 始まりの行番号。
  public let lineNumber: Int
  public let line: String
  public let error: UnifiedDiffParseError
}

public struct UnifiedDiffParseResult: Sendable, Equatable {
  public let files: [UnifiedDiffFile]
  public let failures: [UnifiedDiffParseFailure]
  /// 競合として読み飛ばしたレコードのパスを、出力に現れた順で持つ。読み飛ばしても情報が
  /// 失われていないことを示すためだけにあり、**一覧の生成には使わない** — 競合の一次情報は
  /// `git status` の `u` レコードで、`DiffSnapshotBuilder` はそちらから区分を作る (§9.1.3)。
  ///
  /// 値は行から接頭辞を落とした残りそのままで、`git diff` の patch が path に施す quoting は
  /// 解いていない (`-z` が無いため quote され得る)。突き合わせにも表示にも使わないため。
  ///
  /// そもそも status 側との突き合わせはできない: 同じパスでも記録元で表記が違い、`* Unmerged
  /// path` は quote されないのに `diff --cc` header は quote する (git 2.50.1 で実測:
  /// `* Unmerged path q"uote.txt` と `diff --cc "q\"uote.txt"`)。
  public let unmergedPaths: [String]
}

/// `git diff --patch --no-color` の解析。1ファイルの異常で全体を失わない部分成功型
/// (docs/coding-guidelines.md §2.3)。
public enum UnifiedDiffPatch {
  public static func parse(output: String) -> UnifiedDiffParseResult {
    var lines = output.components(separatedBy: "\n")
    if lines.last?.isEmpty == true { lines.removeLast() }
    var files: [UnifiedDiffFile] = []
    var failures: [UnifiedDiffParseFailure] = []
    var unmergedPaths: [String] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      // 競合中のパスは patch 形式では出ない。unstaged 側は combined diff (`diff --cc`) と
      // `* Unmerged path` の両方を、`--cached` 側は後者だけを出す (git 2.50.1 で実測)。
      if let path = line.value(after: DiffRecord.unmergedPathPrefix) {
        unmergedPaths.append(path)
        // 改行を含まないパスでは1行のレコードで、次の行が通常の `diff --git` ブロックで
        // あり得るため1行だけ進める。改行を含むパスでは quote されずに複数の物理行へ割れ、
        // 2行目以降がここを抜ける (git 2.50.1 で実測。Issue #307)。
        index += 1
        continue
      }
      if let path = DiffRecord.combinedHeaderPath(line) {
        unmergedPaths.append(path)
        index = skipToNextRecord(lines, from: index + 1)
        continue
      }
      guard line.hasPrefix(DiffRecord.gitHeaderPrefix) else {
        failures.append(
          .init(lineNumber: index + 1, line: line, error: .unexpectedLine(line)))
        index = skipToNextRecord(lines, from: index + 1)
        continue
      }
      var parser = FileParser(lines: lines, start: index)
      switch parser.parse() {
      case .success(let file): files.append(file)
      case .failure(let failure): failures.append(failure)
      }
      index =
        parser.recovered ? skipToNextRecord(lines, from: parser.index) : parser.index
    }
    return UnifiedDiffParseResult(
      files: files, failures: failures, unmergedPaths: unmergedPaths)
  }

  private static func skipToNextRecord(_ lines: [String], from index: Int) -> Int {
    var index = index
    while index < lines.count, !DiffRecord.startsRecord(lines[index]) { index += 1 }
    return index
  }
}

/// patch の中でレコードの始まりになり得る行。combined diff の本文行は必ず2文字の接頭辞を
/// 持つので、本文がこれらの語で始まることはない (git 2.50.1 で実測)。
private enum DiffRecord {
  static let gitHeaderPrefix = "diff --git "
  static let unmergedPathPrefix = "* Unmerged path "
  private static let combinedHeaderPrefixes = ["diff --cc ", "diff --combined "]

  static func startsRecord(_ line: String) -> Bool {
    line.hasPrefix(gitHeaderPrefix) || line.hasPrefix(unmergedPathPrefix)
      || combinedHeaderPath(line) != nil
  }

  static func combinedHeaderPath(_ line: String) -> String? {
    combinedHeaderPrefixes.lazy.compactMap { line.value(after: $0) }.first
  }
}

/// 1ファイル分の header・metadata・hunk を読む。`index` は次に読むべき行を指す。
private struct FileParser {
  let lines: [String]
  var index: Int
  var recovered = false

  private let headerLineNumber: Int
  private let header: String
  private var oldPath: String?
  private var newPath: String?
  private var oldMode: String?
  private var newMode: String?
  private var indexMode: String?
  private var oldObject: String?
  private var newObject: String?
  private var renameFrom: String?
  private var renameTo: String?
  private var copyFrom: String?
  private var copyTo: String?
  private var similarity: Int?
  private var isNewFile = false
  private var isDeleted = false
  private var isBinary = false
  private var hunks: [UnifiedDiffHunk] = []

  init(lines: [String], start: Int) {
    self.lines = lines
    index = start + 1
    headerLineNumber = start + 1
    header = lines[start]
  }

  mutating func parse() -> Result<UnifiedDiffFile, UnifiedDiffParseFailure> {
    // `* Unmerged path` は通常ブロックの直後にも来る (git 2.50.1 で実測: `--cached` が
    // 自動マージ済みファイルの patch に続けて出した)。ここで止めないと metadata として
    // 黙って捨てることになる。
    while index < lines.count, !DiffRecord.startsRecord(lines[index]) {
      let line = lines[index]
      if line.hasPrefix("@@") {
        if let failure = consumeHunk() { return .failure(failure) }
        continue
      }
      consumeMetadata(line)
      index += 1
    }
    return build()
  }

  // 1行の種別ごとの分岐そのものが仕様であり、分割すると git の出力形式との対応が読めなくなる。
  // swiftlint:disable:next cyclomatic_complexity
  private mutating func consumeMetadata(_ line: String) {
    if let value = line.value(after: "old mode ") {
      oldMode = value
    } else if let value = line.value(after: "new file mode ") {
      newMode = value
      isNewFile = true
    } else if let value = line.value(after: "new mode ") {
      newMode = value
    } else if let value = line.value(after: "deleted file mode ") {
      oldMode = value
      isDeleted = true
    } else if let value = line.value(after: "similarity index ") {
      similarity = Int(value.hasSuffix("%") ? String(value.dropLast()) : value)
    } else if let value = line.value(after: "rename from ") {
      renameFrom = value
    } else if let value = line.value(after: "rename to ") {
      renameTo = value
    } else if let value = line.value(after: "copy from ") {
      copyFrom = value
    } else if let value = line.value(after: "copy to ") {
      copyTo = value
    } else if let value = line.value(after: "index ") {
      // `index <old>..<new> <mode>`。mode は両側で同じときだけ付く。
      let fields = value.split(separator: " ")
      if fields.count == 2 { indexMode = String(fields[1]) }
      let objects = fields.first?.components(separatedBy: "..") ?? []
      if objects.count == 2 {
        oldObject = objects[0]
        newObject = objects[1]
      }
    } else if let value = line.value(after: "--- ") {
      oldPath = Self.path(fromMarker: value, prefix: "a/")
    } else if let value = line.value(after: "+++ ") {
      newPath = Self.path(fromMarker: value, prefix: "b/")
    } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
      isBinary = true
    }
    // それ以外 (dissimilarity index、binary patch の base85 本文等) は、次の `diff --git` まで
    // 読み飛ばす。中身を推測で作らない (§25 で binary Diff の表示は未確定)。
  }

  private mutating func consumeHunk() -> UnifiedDiffParseFailure? {
    let headerIndex = index
    let line = lines[headerIndex]
    guard let parsed = HunkHeader(line: line) else {
      recovered = true
      index = headerIndex + 1
      return .init(
        lineNumber: headerIndex + 1, line: line, error: .invalidHunkHeader(line))
    }
    index += 1
    var remainingOld = parsed.oldCount
    var remainingNew = parsed.newCount
    var oldNumber = parsed.oldStart
    var newNumber = parsed.newStart
    var body: [UnifiedDiffLine] = []
    while remainingOld > 0 || remainingNew > 0 {
      guard index < lines.count else {
        return truncated(headerIndex: headerIndex, old: remainingOld, new: remainingNew)
      }
      let line = lines[index]
      if line.hasPrefix("\\") {
        Self.markMissingTrailingNewline(&body)
        index += 1
        continue
      }
      guard let kind = Self.lineKind(of: line) else {
        return truncated(headerIndex: headerIndex, old: remainingOld, new: remainingNew)
      }
      let consumesOld = kind != .added
      let consumesNew = kind != .removed
      guard !consumesOld || remainingOld > 0, !consumesNew || remainingNew > 0 else {
        return truncated(headerIndex: headerIndex, old: remainingOld, new: remainingNew)
      }
      let text = line.isEmpty ? "" : String(line.dropFirst())
      body.append(
        UnifiedDiffLine(
          kind: kind,
          oldLineNumber: consumesOld ? oldNumber : nil,
          newLineNumber: consumesNew ? newNumber : nil,
          text: text))
      if consumesOld {
        oldNumber += 1
        remainingOld -= 1
      }
      if consumesNew {
        newNumber += 1
        remainingNew -= 1
      }
      index += 1
    }
    // 本文の直後に付く `\ No newline at end of file` は行数に数えられない。
    if index < lines.count, lines[index].hasPrefix("\\") {
      Self.markMissingTrailingNewline(&body)
      index += 1
    }
    hunks.append(
      UnifiedDiffHunk(
        oldStart: parsed.oldStart, oldCount: parsed.oldCount, newStart: parsed.newStart,
        newCount: parsed.newCount, section: parsed.section, lines: body))
    return nil
  }

  /// `\ No newline at end of file` は直前の行に付く。
  private static func markMissingTrailingNewline(_ body: inout [UnifiedDiffLine]) {
    guard let last = body.last else { return }
    body[body.count - 1] = UnifiedDiffLine(
      kind: last.kind, oldLineNumber: last.oldLineNumber, newLineNumber: last.newLineNumber,
      text: last.text, isMissingTrailingNewline: true)
  }

  /// `diff.suppressBlankEmpty` が立つと、空の context 行は空行として出る。
  private static func lineKind(of line: String) -> UnifiedDiffLineKind? {
    if line.hasPrefix("+") { return .added }
    if line.hasPrefix("-") { return .removed }
    if line.hasPrefix(" ") || line.isEmpty { return .context }
    return nil
  }

  private mutating func truncated(
    headerIndex: Int, old: Int, new: Int
  ) -> UnifiedDiffParseFailure {
    recovered = true
    return .init(
      lineNumber: headerIndex + 1, line: lines[headerIndex],
      error: .truncatedHunk(remainingOld: old, remainingNew: new))
  }

  private func build() -> Result<UnifiedDiffFile, UnifiedDiffParseFailure> {
    var oldPath = oldPath
    var newPath = newPath
    var changeKind: UnifiedDiffChangeKind = .modified
    if let renameFrom, let renameTo {
      oldPath = renameFrom
      newPath = renameTo
      changeKind = .renamed(from: renameFrom, similarity: similarity)
    } else if let copyFrom, let copyTo {
      oldPath = copyFrom
      newPath = copyTo
      changeKind = .copied(from: copyFrom, similarity: similarity)
    } else if isNewFile {
      changeKind = .added
    } else if isDeleted {
      changeKind = .deleted
    }
    if oldPath == nil, newPath == nil {
      guard let paths = Self.headerPaths(header) else {
        return .failure(
          .init(
            lineNumber: headerLineNumber, line: header, error: .ambiguousHeaderPaths(header)))
      }
      oldPath = isNewFile ? nil : paths.old
      newPath = isDeleted ? nil : paths.new
    }
    let content: UnifiedDiffContent =
      isBinary ? .binary : (hunks.isEmpty ? .noContentChange : .hunks(hunks))
    return .success(
      UnifiedDiffFile(
        oldPath: oldPath,
        newPath: newPath,
        changeKind: changeKind,
        oldMode: oldMode ?? indexMode,
        newMode: newMode ?? indexMode,
        oldObject: oldObject,
        newObject: newObject,
        content: content))
  }

  /// `--- /dev/null` は「その側に存在しない」を意味する。
  ///
  /// git は **path に空白が含まれれば、quote の有無によらず** 分離子として末尾へ TAB を付ける
  /// (git 2.50.1 で実測: `--- a/sp ace.txt\t` と `--- "a/He said \"hi\" there.txt"\t`)。
  /// 一方で quote された値は必ず `"` で終わり、空白を含まない path には TAB が付かない
  /// (`--- "a/trailtab\t"` は末尾が本物の TAB でも分離子なし)。したがって**末尾の TAB 1 個は
  /// 常に分離子**であり、unquote より先に落とす。順序を逆にすると、空白と quote 強制文字が
  /// 同居する名前で unquote が失敗し、引用符も `a/` / `b/` prefix も残ったリテラルになる。
  /// 落とさないと同じ snapshot 内で status 由来の untracked と表現が食い違う (§9.1.3)。
  private static func path(fromMarker value: String, prefix: String) -> String? {
    if value == "/dev/null" { return nil }
    let separated = value.hasSuffix("\t") ? String(value.dropLast()) : value
    let unquoted = unquote(separated) ?? separated
    return unquoted.hasPrefix(prefix) ? String(unquoted.dropFirst(prefix.count)) : unquoted
  }

  /// `diff --git a/x b/y` から path を取る。path に空白が入ると切れ目が一意に決まらないため、
  /// 両側が同じ path になる分割だけを採り、決められなければ `nil` を返す。
  private static func headerPaths(_ header: String) -> (old: String, new: String)? {
    let rest = String(header.dropFirst("diff --git ".count))
    if rest.hasPrefix("\"") { return quotedHeaderPaths(rest) }
    var candidates: [(String, String)] = []
    var searchStart = rest.startIndex
    while let found = rest.range(of: " b/", range: searchStart..<rest.endIndex) {
      let left = String(rest[rest.startIndex..<found.lowerBound])
      let right = String(rest[rest.index(after: found.lowerBound)...])
      if left.hasPrefix("a/"), right.hasPrefix("b/") {
        candidates.append((String(left.dropFirst(2)), String(right.dropFirst(2))))
      }
      searchStart =
        found.lowerBound < rest.endIndex ? rest.index(after: found.lowerBound) : rest.endIndex
    }
    if let same = candidates.first(where: { $0.0 == $0.1 }) { return same }
    guard candidates.count == 1, let only = candidates.first else { return nil }
    return only
  }

  private static func quotedHeaderPaths(_ rest: String) -> (old: String, new: String)? {
    guard let (first, afterFirst) = takeQuoted(rest), first.hasPrefix("a/"),
      afterFirst < rest.endIndex, rest[afterFirst] == " "
    else { return nil }
    let secondStart = rest.index(after: afterFirst)
    let tail = String(rest[secondStart...])
    let second = tail.hasPrefix("\"") ? takeQuoted(tail)?.0 : tail
    guard let second, second.hasPrefix("b/") else { return nil }
    return (String(first.dropFirst(2)), String(second.dropFirst(2)))
  }

  /// 返す index は閉じ引用符の次の位置。
  private static func takeQuoted(_ value: String) -> (String, String.Index)? {
    var index = value.index(after: value.startIndex)
    while index < value.endIndex {
      if value[index] == "\\" {
        index = value.index(index, offsetBy: 2, limitedBy: value.endIndex) ?? value.endIndex
        continue
      }
      if value[index] == "\"" { break }
      index = value.index(after: index)
    }
    guard index < value.endIndex else { return nil }
    let closing = value.index(after: index)
    guard let unquoted = unquote(String(value[value.startIndex..<closing])) else { return nil }
    return (unquoted, closing)
  }

  // git の C style quoting。`core.quotePath=false` でも path に `"` や制御文字が入ると
  // この形で出るため、UTF-8 バイト列へ戻してから復号する。
  // escape 表現ごとの分岐が仕様そのもので、分割しても読みやすくならない。
  // swiftlint:disable:next cyclomatic_complexity
  private static func unquote(_ value: String) -> String? {
    guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
    var bytes: [UInt8] = []
    var iterator = Array(value.dropFirst().dropLast().utf8).makeIterator()
    while let byte = iterator.next() {
      guard byte == UInt8(ascii: "\\") else {
        bytes.append(byte)
        continue
      }
      guard let next = iterator.next() else { return nil }
      switch next {
      case UInt8(ascii: "n"): bytes.append(0x0A)
      case UInt8(ascii: "t"): bytes.append(0x09)
      case UInt8(ascii: "r"): bytes.append(0x0D)
      case UInt8(ascii: "\\"), UInt8(ascii: "\""): bytes.append(next)
      case UInt8(ascii: "0")...UInt8(ascii: "7"):
        guard let second = iterator.next(), let third = iterator.next() else { return nil }
        let digits = [next, second, third].map { Int($0) - 48 }
        guard digits.allSatisfy({ (0...7).contains($0) }) else { return nil }
        bytes.append(UInt8(digits[0] * 64 + digits[1] * 8 + digits[2]))
      default: return nil
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

private struct HunkHeader {
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int
  let section: String

  init?(line: String) {
    guard line.hasPrefix("@@ -") else { return nil }
    let rest = line.dropFirst(4)
    guard let terminator = rest.range(of: " @@") else { return nil }
    let fields = rest[rest.startIndex..<terminator.lowerBound].split(separator: " ")
    guard fields.count == 2, fields[1].hasPrefix("+"),
      let old = Self.range(String(fields[0])),
      let new = Self.range(String(fields[1].dropFirst()))
    else { return nil }
    oldStart = old.start
    oldCount = old.count
    newStart = new.start
    newCount = new.count
    let trailing = rest[terminator.upperBound...]
    section = trailing.hasPrefix(" ") ? String(trailing.dropFirst()) : String(trailing)
  }

  /// `<start>` は `<start>,1` と同じ意味 (unified diff の既定)。
  private static func range(_ value: String) -> (start: Int, count: Int)? {
    let parts = value.split(separator: ",", omittingEmptySubsequences: false)
    guard let start = Int(parts[0]), start >= 0 else { return nil }
    if parts.count == 1 { return (start, 1) }
    guard parts.count == 2, let count = Int(parts[1]), count >= 0 else { return nil }
    return (start, count)
  }
}

extension String {
  fileprivate func value(after prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
