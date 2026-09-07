import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// fixture は `/tmp/awt-rg-fixture` を worktree root に見立てて rg 15.2.0 を実行した実出力。
private let fixtureRoot = "/tmp/awt-rg-fixture"

private func fixture(_ name: String) throws -> String {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

private func record(
  _ output: RipgrepJSONOutput, path: String, line: Int
) -> RipgrepMatchRecord? {
  output.matches.first { $0.absolutePath == fixtureRoot + "/" + path && $0.lineNumber == line }
}

@Suite("§8.2 rg --json のパース")
struct RipgrepJSONOutputParserTests {
  @Test("gitignore 尊重 scope では ignored / hidden / .git を含まない")
  func gitignoreScope() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-gitignore-scope.jsonl"))
    let paths = Set(output.matches.map(\.absolutePath))
    #expect(paths.contains(fixtureRoot + "/a.txt"))
    #expect(paths.contains(fixtureRoot + "/sub/b.txt"))
    #expect(!paths.contains(fixtureRoot + "/ignored.txt"))
    #expect(!paths.contains(fixtureRoot + "/.hidden.txt"))
    #expect(!paths.contains(fixtureRoot + "/.git/config"))
    #expect(output.didFinish)
    #expect(output.failures.isEmpty)
  }

  @Test("全ファイル scope では ignored / hidden を含み .git は含まない")
  func allFilesScope() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-all-files-scope.jsonl"))
    let paths = Set(output.matches.map(\.absolutePath))
    #expect(paths.contains(fixtureRoot + "/ignored.txt"))
    #expect(paths.contains(fixtureRoot + "/.hidden.txt"))
    #expect(!paths.contains(fixtureRoot + "/.git/config"))
  }

  @Test("バイナリファイルは結果に出ない")
  func skipsBinary() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-all-files-scope.jsonl"))
    #expect(!output.matches.contains { $0.absolutePath.hasSuffix("bin.dat") })
  }

  @Test("0 件でも summary は届き、失敗として扱わない")
  func noMatch() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-no-match.jsonl"))
    #expect(output.matches.isEmpty)
    #expect(output.didFinish)
    #expect(output.failures.isEmpty)
    #expect(output.filesReachingPerFileLimit.isEmpty)
  }

  @Test("不正な正規表現では stdout が空で、探索が完了していないと分かる")
  func badRegularExpression() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-bad-regex-stdout.jsonl"))
    #expect(output.didFinish == false)
    #expect(output.matches.isEmpty)
    #expect(output.failures.isEmpty)
  }

  @Test("上限 + 1 件目が来たファイルを打ち切りと判定し、余分な1件は捨てる")
  func detectsPerFileLimit() throws {
    let output = RipgrepJSONOutputParser.parse(
      try fixture("rg-15.2.0-json-gitignore-scope.jsonl"), perFileLimit: 100)
    #expect(output.filesReachingPerFileLimit == [fixtureRoot + "/many.txt"])
    let manyMatches = output.matches.filter { $0.absolutePath.hasSuffix("many.txt") }
    #expect(manyMatches.count == 100)
    #expect(manyMatches.last?.lineNumber == 100)
  }

  @Test("上限に達していないファイルは打ち切りにしない")
  func doesNotReportUntruncatedFiles() throws {
    let output = RipgrepJSONOutputParser.parse(
      try fixture("rg-15.2.0-json-gitignore-scope.jsonl"), perFileLimit: 100)
    #expect(!output.filesReachingPerFileLimit.contains { $0.hasSuffix("a.txt") })
  }

  @Test("マルチバイト行のマッチはバイトオフセットで届く")
  func multibyteSubmatchIsByteOffset() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-gitignore-scope.jsonl"))
    let match = try #require(record(output, path: "mb.txt", line: 1))
    #expect(match.submatchByteRanges == [19..<24])
    #expect(String(decoding: match.lineBytes, as: UTF8.self) == "マルチバイト hello テスト\n")
  }

  @Test("非 UTF-8 の行は bytes で届き、生バイトのまま保つ")
  func nonUTF8LineArrivesAsBytes() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-gitignore-scope.jsonl"))
    let match = try #require(record(output, path: "nonutf8.txt", line: 1))
    #expect(match.lineBytes == Array("prefix ".utf8) + [0xFF, 0xFE] + Array(" hello tail\n".utf8))
    #expect(match.submatchByteRanges == [10..<15])
  }

  @Test("--max-columns は --json 出力に効かないため、長い行がそのまま届く")
  func longLineArrivesWhole() throws {
    let output = RipgrepJSONOutputParser.parse(try fixture("rg-15.2.0-json-gitignore-scope.jsonl"))
    let match = try #require(record(output, path: "long.txt", line: 1))
    #expect(match.lineBytes.count == 1_208)
    #expect(match.submatchByteRanges == [601..<606])
  }

  @Test("未知の type は無視し、壊れない")
  func ignoresUnknownEventType() {
    let stdout = [
      #"{"type":"begin","data":{"path":{"text":"/w/a.txt"}}}"#,
      #"{"type":"context","data":{"path":{"text":"/w/a.txt"},"lines":{"text":"x\n"}}}"#,
      #"{"type":"future-event","data":42}"#,
      matchEvent(path: #"{"text":"/w/a.txt"}"#, lines: #"{"text":"hello\n"}"#, submatches: [0..<5]),
      #"{"type":"end","data":{"path":{"text":"/w/a.txt"},"binary_offset":null}}"#,
      summaryEvent,
    ].joined(separator: "\n")
    let output = RipgrepJSONOutputParser.parse(stdout)
    #expect(output.matches.count == 1)
    #expect(output.failures.isEmpty)
    #expect(output.didFinish)
  }

  @Test("JSON として読めない行は原文つきの失敗として残り、他の行は生き残る")
  func recordsUnparsableLines() {
    let stdout = [
      "not json at all",
      matchEvent(path: #"{"text":"/w/a.txt"}"#, lines: #"{"text":"hello\n"}"#),
      summaryEvent,
    ].joined(separator: "\n")
    let output = RipgrepJSONOutputParser.parse(stdout)
    #expect(output.failures.count == 1)
    #expect(output.failures.first?.lineNumber == 1)
    #expect(output.failures.first?.rawLine == "not json at all")
    #expect(output.matches.count == 1)
  }

  @Test("非 UTF-8 のパスは bytes 側から置換文字つきで復元する")
  func decodesNonUTF8Path() throws {
    // macOS の APFS では作れないファイル名 (実測: EILSEQ) なので、rg の形式に合わせて組み立てる。
    let encoded = Data(Array("/w/".utf8) + [0xFF] + Array(".txt".utf8)).base64EncodedString()
    let stdout = [
      matchEvent(path: #"{"bytes":"\#(encoded)"}"#, lines: #"{"text":"hello\n"}"#),
      summaryEvent,
    ].joined(separator: "\n")
    let output = RipgrepJSONOutputParser.parse(stdout)
    let match = try #require(output.matches.first)
    #expect(match.absolutePath == "/w/\u{FFFD}.txt")
    #expect(output.failures.isEmpty)
  }

  @Test("行の範囲外を指す submatch は捨てる")
  func dropsOutOfBoundsSubmatch() throws {
    let stdout = [
      matchEvent(path: #"{"text":"/w/a.txt"}"#, lines: #"{"text":"hi\n"}"#, submatches: [0..<99]),
      summaryEvent,
    ].joined(separator: "\n")
    let output = RipgrepJSONOutputParser.parse(stdout)
    #expect(output.matches.first?.submatchByteRanges.isEmpty == true)
  }
}

private let summaryEvent = #"{"type":"summary","data":{}}"#

/// rg 15.2.0 の `match` イベントと同じ形を、行を短く保ったまま組み立てる。
private func matchEvent(
  path: String, lines: String, lineNumber: Int = 1, submatches: [Range<Int>] = []
) -> String {
  let encoded =
    submatches
    .map { #"{"match":{"text":"x"},"start":\#($0.lowerBound),"end":\#($0.upperBound)}"# }
    .joined(separator: ",")
  return #"{"type":"match","data":{"path":\#(path),"lines":\#(lines),"#
    + #""line_number":\#(lineNumber),"absolute_offset":0,"submatches":[\#(encoded)]}}"#
}

@Suite("§8.2 行テキストとマッチ位置")
struct RipgrepLineTextTests {
  @Test("行末の改行を落とす", arguments: ["hello\n", "hello\r\n", "hello"])
  func stripsLineTerminator(raw: String) throws {
    let line = try #require(
      RipgrepLineText.line(fromBytes: Array(raw.utf8), submatchByteRanges: [0..<5]))
    #expect(line.text == "hello")
    #expect(line.isTruncated == false)
  }

  @Test("マルチバイト行のバイトオフセットを行テキスト上の位置へ変換する")
  func convertsMultibyteOffsets() throws {
    let raw = "マルチバイト hello テスト\n"
    let line = try #require(
      RipgrepLineText.line(fromBytes: Array(raw.utf8), submatchByteRanges: [19..<24]))
    let range = try #require(line.matches.first)
    #expect(String(line.text[range]) == "hello")
  }

  @Test("非 UTF-8 の行は置換文字へ落としたうえで位置がずれない")
  func convertsOffsetsAcrossLossyDecoding() throws {
    let bytes = Array("prefix ".utf8) + [0xFF, 0xFE] + Array(" hello tail\n".utf8)
    let line = try #require(
      RipgrepLineText.line(fromBytes: bytes, submatchByteRanges: [10..<15]))
    #expect(line.text == "prefix \u{FFFD}\u{FFFD} hello tail")
    let range = try #require(line.matches.first)
    #expect(String(line.text[range]) == "hello")
  }

  @Test("表示幅の上限で切り、切ったことを行から読める")
  func truncatesAtMaximumColumns() throws {
    let raw = String(repeating: "x", count: 600) + " hello " + String(repeating: "y", count: 600)
    let line = try #require(
      RipgrepLineText.line(
        fromBytes: Array((raw + "\n").utf8), submatchByteRanges: [601..<606],
        maximumColumns: 500))
    #expect(line.text.count == 500)
    #expect(line.isTruncated)
    // 601 バイト目のマッチは 500 桁の外なので、位置を持たない。
    #expect(line.matches.isEmpty)
  }

  @Test("上限内のマッチは切り詰め後も位置を保つ")
  func keepsMatchesInsideTruncation() throws {
    let raw = "hello " + String(repeating: "y", count: 600)
    let line = try #require(
      RipgrepLineText.line(
        fromBytes: Array((raw + "\n").utf8), submatchByteRanges: [0..<5], maximumColumns: 500))
    #expect(line.isTruncated)
    let range = try #require(line.matches.first)
    #expect(String(line.text[range]) == "hello")
  }

  @Test("上限ちょうどの行は切らない")
  func doesNotTruncateAtExactLimit() throws {
    let raw = String(repeating: "x", count: 500)
    let line = try #require(
      RipgrepLineText.line(
        fromBytes: Array((raw + "\n").utf8), submatchByteRanges: [], maximumColumns: 500))
    #expect(line.isTruncated == false)
    #expect(line.text.count == 500)
  }
}
