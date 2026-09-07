import Foundation
import TerminalCore
import Testing

@testable import Adapters

// この suite は ProcessRunning mock のみを使い、rg は実行しない。
// stdout の fixture は `/tmp/awt-rg-fixture` に対する rg 15.2.0 の実出力。
private let fixtureRoot = URL(fileURLWithPath: "/tmp/awt-rg-fixture")

private func fixture(_ name: String) throws -> String {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

private func matchEvent(path: String, text: String) -> String {
  #"{"type":"match","data":{"path":{"text":"\#(path)"},"lines":{"text":"\#(text)"},"#
    + #""line_number":1,"submatches":[]}}"#
}

private func query(
  _ term: String,
  scope: WorktreeSearchScope = .respectingGitignore,
  usesRegularExpression: Bool = false,
  target: WorktreeSearchTarget = .fullText
) throws -> WorktreeSearchQuery {
  try #require(
    WorktreeSearchQuery(
      term: term, scope: scope, usesRegularExpression: usesRegularExpression, target: target))
}

@Suite("§8.2 ripgrep 実行境界")
struct RipgrepRunnerTests {
  @Test("標準候補は端末で優先される配置順にする")
  func ordersDefaultCandidates() {
    #expect(
      RipgrepRunner.defaultExecutableCandidates.map(\.path) == [
        "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg",
      ])
  }

  @Test("rg がどこにも無ければ binaryNotFound を投げる")
  func reportsMissingBinary() {
    let candidates = [URL(fileURLWithPath: "/rg")]
    #expect(throws: RipgrepRunnerError.binaryNotFound(candidates: candidates)) {
      try makeRunner(spy: RipgrepProcessSpy(results: []), executable: false)
    }
  }

  @Test("worktree root は絶対パスの file URL であること")
  func validatesWorktreeRoot() {
    let relative = URL(fileURLWithPath: "wt", relativeTo: URL(fileURLWithPath: "/base"))
    #expect(throws: RipgrepRunnerError.invalidWorktreeRoot(relative)) {
      try makeRunner(spy: RipgrepProcessSpy(results: []), root: relative)
    }
  }

  @Test("gitignore 尊重 scope・固定文字列・上限 + 1 で起動する")
  func buildsDefaultSearchCommand() throws {
    #expect(
      RipgrepCommand.search(try query("foo"), worktreeRoot: fixtureRoot, perFileLimit: 100)
        .arguments == [
          "--json", "--no-config", "--smart-case", "--max-count", "101", "--fixed-strings",
          "--", "foo", "/tmp/awt-rg-fixture",
        ])
  }

  @Test("全ファイル scope でも .git は常に除く")
  func buildsAllFilesSearchCommand() throws {
    #expect(
      RipgrepCommand.search(
        try query("foo", scope: .allFiles, usesRegularExpression: true),
        worktreeRoot: fixtureRoot, perFileLimit: 100
      ).arguments == [
        "--json", "--no-config", "--smart-case", "--max-count", "101", "--no-ignore", "--hidden",
        "--glob", "!.git", "--", "foo", "/tmp/awt-rg-fixture",
      ])
  }

  @Test("`-` で始まる検索語は option として読まれない")
  func separatesTermFromOptions() throws {
    let arguments = RipgrepCommand.search(try query("-n"), worktreeRoot: fixtureRoot).arguments
    let separator = try #require(arguments.firstIndex(of: "--"))
    #expect(arguments[separator + 1] == "-n")
  }

  @Test("ファイル一覧は NUL 区切りで取る")
  func buildsFileListCommand() {
    #expect(
      RipgrepCommand.listFiles(scope: .respectingGitignore, worktreeRoot: fixtureRoot).arguments
        == ["--files", "--null", "--no-config", "--", "/tmp/awt-rg-fixture"])
    #expect(
      RipgrepCommand.listFiles(scope: .allFiles, worktreeRoot: fixtureRoot).arguments
        == [
          "--files", "--null", "--no-config", "--no-ignore", "--hidden", "--glob", "!.git",
          "--", "/tmp/awt-rg-fixture",
        ])
  }

  @Test("限定環境と既定のタイムアウト・出力上限を実行層へ渡す")
  func passesEnvironmentAndLimits() async throws {
    let spy = RipgrepProcessSpy(results: [.success(.init(exitCode: 1, stdout: "", stderr: ""))])
    let runner = try makeRunner(spy: spy)
    _ = try await runner.run(.listFiles(scope: .respectingGitignore, worktreeRoot: fixtureRoot))
    let call = try #require(await spy.calls.first)
    #expect(call.environment == ["LC_ALL": "C", "HOME": "/home", "PATH": "/bin"])
    #expect(call.timeout == .seconds(15))
    #expect(call.outputLimit == RipgrepRunner.defaultOutputLimit)
  }

  // 既定の 8 MiB は1文字クエリ (実測 7.0 MB / 全ファイル scope 43.5 MB) で尽きる。
  // 超えると部分出力ごと捨てるので、1,000 件上限が効くべき場面で 0 件になる。
  @Test("検索とファイル一覧は既定より広い出力上限で実行する")
  func usesWiderOutputLimitForSearch() async throws {
    let spy = RipgrepProcessSpy(
      results: [
        .success(.init(exitCode: 1, stdout: "", stderr: "")),
        .success(.init(exitCode: 0, stdout: "/tmp/awt-rg-fixture/a.txt\0", stderr: "")),
      ])
    let search = RipgrepSearch(runner: try makeRunner(spy: spy))
    _ = try await search.search(try query("foo"))
    _ = try await search.listFiles(scope: .respectingGitignore)
    let limits = await spy.calls.map(\.outputLimit)
    #expect(limits == [RipgrepRunner.searchOutputLimit, RipgrepRunner.searchOutputLimit])
    #expect(RipgrepRunner.searchOutputLimit > ProcessRunLimits.defaultOutputBytes)
  }

  @Test("終了コードはエラーにしない — 2 でも stdout が揃っていることがある")
  func doesNotConvertExitCodeToError() async throws {
    let spy = RipgrepProcessSpy(results: [.success(.init(exitCode: 2, stdout: "x", stderr: "e"))])
    let runner = try makeRunner(spy: spy)
    let result = try await runner.run(.search(try query("foo"), worktreeRoot: fixtureRoot))
    #expect(result.exitCode == 2)
    #expect(result.stderr == "e")
  }

  @Test("出力上限超過は「結果が多すぎる」として上がる")
  func surfacesOutputLimit() async throws {
    let limit = ProcessRunLimits.defaultOutputBytes
    let spy = RipgrepProcessSpy(results: [.failure(.outputLimitExceeded(limit: limit))])
    let runner = try makeRunner(spy: spy)
    await #expect(throws: RipgrepRunnerError.tooManyResults(outputLimit: limit)) {
      try await runner.run(.search(try query("foo"), worktreeRoot: fixtureRoot))
    }
  }

  @Test("タイムアウトとキャンセルは他の実行層エラーと区別できる")
  func distinguishesTimeoutAndCancellation() async throws {
    let timedOut = RipgrepProcessSpy(results: [
      .failure(.timedOut(exitCode: nil, stdout: "", stderr: ""))
    ])
    await #expect(throws: RipgrepRunnerError.timedOut(seconds: 15)) {
      try await makeRunner(spy: timedOut).run(
        .search(try query("foo"), worktreeRoot: fixtureRoot))
    }
    let cancelled = RipgrepProcessSpy(results: [.failure(.cancelled)])
    await #expect(throws: RipgrepRunnerError.cancelled) {
      try await makeRunner(spy: cancelled).run(
        .search(try query("foo"), worktreeRoot: fixtureRoot))
    }
  }
}

@Suite("§8 検索結果の組み立て")
struct RipgrepSearchTests {
  @Test("worktree 相対パス・行番号・行テキストを持つ結果になる")
  func buildsDomainResults() async throws {
    let report = try await search(stdout: try fixture("rg-15.2.0-json-gitignore-scope.jsonl"))
    let match = try #require(
      report.outcome.matches.first { $0.path.value == "mb.txt" && $0.lineNumber == 1 })
    let range = try #require(match.line.matches.first)
    #expect(String(match.line.text[range]) == "hello")
    #expect(match.line.text == "マルチバイト hello テスト")
    #expect(report.didFinish)
  }

  @Test("1ファイルあたりの打ち切りが結果から読める")
  func reportsPerFileTruncation() async throws {
    let report = try await search(stdout: try fixture("rg-15.2.0-json-gitignore-scope.jsonl"))
    #expect(report.outcome.truncation.filesReachingPerFileLimit.map(\.value) == ["many.txt"])
    #expect(report.outcome.truncation.reachedResultLimit == false)
  }

  @Test("全体上限で切ったことが、ファイル単位の打ち切りと区別できる")
  func reportsResultLimitTruncation() async throws {
    let report = try await search(
      stdout: try fixture("rg-15.2.0-json-gitignore-scope.jsonl"), resultLimit: 5)
    #expect(report.outcome.matches.count == 5)
    #expect(report.outcome.truncation.reachedResultLimit)
  }

  @Test("0 件は打ち切りでも失敗でもない")
  func reportsEmptyResult() async throws {
    let report = try await search(
      stdout: try fixture("rg-15.2.0-json-no-match.jsonl"), exitCode: 1)
    #expect(report.outcome.matches.isEmpty)
    #expect(report.outcome.truncation.isTruncated == false)
    #expect(report.didFinish)
    #expect(report.warnings.isEmpty)
  }

  @Test("worktree の外を指す結果は捨て、捨てたことを数える")
  func discardsResultsOutsideWorktree() async throws {
    let stdout = [
      matchEvent(path: "/etc/passwd", text: #"root\n"#),
      matchEvent(path: fixtureRoot.path + "/a.txt", text: #"hello\n"#),
      #"{"type":"summary","data":{}}"#,
    ].joined(separator: "\n")
    let report = try await search(stdout: stdout)
    #expect(report.outcome.matches.map(\.path.value) == ["a.txt"])
    #expect(report.discardedOutOfScopeCount == 1)
  }

  @Test("探索が始まらなかった場合だけ commandFailed になる")
  func failsOnlyWhenSearchNeverRan() async throws {
    await #expect(
      throws: RipgrepRunnerError.commandFailed(exitCode: 2, stderr: "regex parse error")
    ) {
      try await search(stdout: "", exitCode: 2, stderr: "regex parse error")
    }
  }

  @Test("一部を読めなかった実行は結果を返しつつ stderr を警告として残す")
  func keepsPartialResultsWithWarning() async throws {
    let report = try await search(
      stdout: try fixture("rg-15.2.0-json-gitignore-scope.jsonl"), exitCode: 2,
      stderr: "rg: /tmp/awt-rg-fixture/noperm: Permission denied (os error 13)")
    #expect(!report.outcome.matches.isEmpty)
    #expect(report.warnings.contains("Permission denied"))
  }

  @Test("ファイル一覧は worktree 相対パスになり、外を指すものは捨てる")
  func listsFilesAsRelativePaths() async throws {
    let spy = RipgrepProcessSpy(
      results: [
        .success(
          .init(
            exitCode: 0, stdout: try fixture("rg-15.2.0-files-null.txt") + "/etc/passwd\0",
            stderr: ""))
      ])
    let report = try await makeSearch(spy: spy).listFiles(scope: .respectingGitignore)
    #expect(
      report.paths.map(\.value).sorted() == [
        "a.txt", "bin.dat", "crlf.txt", "long.txt", "many.txt", "mb.txt", "nonutf8.txt",
        "seed.txt", "sub/b.txt",
      ])
    #expect(report.discardedOutOfScopeCount == 1)
  }

  // fixture は実 `git worktree add` で作った worktree に対する出力なので、`.git` は
  // ディレクトリではなくファイル。`--glob '!.git/'` へ戻すとこのテストが落ちる。
  @Test("全ファイル scope のファイル一覧に worktree の .git が現れない")
  func fileListingExcludesWorktreeGitFile() async throws {
    let spy = RipgrepProcessSpy(
      results: [
        .success(
          .init(
            exitCode: 0, stdout: try fixture("rg-15.2.0-files-null-all-files.txt"), stderr: ""))
      ])
    let report = try await makeSearch(spy: spy).listFiles(scope: .allFiles)
    #expect(!report.paths.map(\.value).contains(".git"))
    // ignored / hidden は拾えていること — 空振りで通っていないことの担保。
    #expect(report.paths.map(\.value).contains("ignored.txt"))
    #expect(report.paths.map(\.value).contains(".hidden.txt"))
  }

  @Test("全ファイル scope の全文検索に worktree の .git が現れない")
  func searchExcludesWorktreeGitFile() async throws {
    let report = try await search(stdout: try fixture("rg-15.2.0-json-all-files-scope.jsonl"))
    let paths = report.outcome.matches.map(\.path.value)
    #expect(!paths.contains(".git"))
    #expect(paths.contains("ignored.txt"))
    #expect(paths.contains(".hidden.txt"))
  }

  @Test("CRLF の行でも行末 CR まで届いたマッチ範囲を保つ")
  func keepsMatchesOnCarriageReturnLines() async throws {
    let report = try await search(stdout: try fixture("rg-15.2.0-json-crlf-regex.jsonl"))
    let match = try #require(report.outcome.matches.first { $0.lineNumber == 1 })
    #expect(match.line.text == "crlf hello world")
    let range = try #require(match.line.matches.first)
    #expect(String(match.line.text[range]) == "hello world")
  }

  @Test("不正な正規表現の stderr がそのまま利用者へ届く")
  func surfacesBadRegularExpressionStderr() async throws {
    let stderr = try fixture("rg-15.2.0-bad-regex-stderr.txt")
    await #expect(throws: RipgrepRunnerError.commandFailed(exitCode: 2, stderr: stderr)) {
      try await search(
        stdout: try fixture("rg-15.2.0-json-bad-regex-stdout.jsonl"), exitCode: 2, stderr: stderr)
    }
  }

  @Test("ファイル一覧が1件も取れない失敗は commandFailed になる")
  func failsWhenFileListingProducesNothing() async throws {
    let spy = RipgrepProcessSpy(
      results: [.success(.init(exitCode: 2, stdout: "", stderr: "No such file or directory"))])
    await #expect(
      throws: RipgrepRunnerError.commandFailed(exitCode: 2, stderr: "No such file or directory")
    ) {
      try await makeSearch(spy: spy).listFiles(scope: .respectingGitignore)
    }
  }

  private func search(
    stdout: String, exitCode: Int32 = 0, stderr: String = "", resultLimit: Int = 1_000
  ) async throws -> RipgrepSearchReport {
    let spy = RipgrepProcessSpy(
      results: [.success(.init(exitCode: exitCode, stdout: stdout, stderr: stderr))])
    return try await makeSearch(spy: spy).search(try query("hello"), resultLimit: resultLimit)
  }

  private func makeSearch(spy: RipgrepProcessSpy) throws -> RipgrepSearch {
    RipgrepSearch(runner: try makeRunner(spy: spy))
  }
}

private func makeRunner(
  spy: RipgrepProcessSpy, root: URL = fixtureRoot, executable: Bool = true
) throws -> RipgrepRunner {
  try RipgrepRunner(
    worktreeRoot: root, processRunner: spy,
    executableCandidates: [URL(fileURLWithPath: "/rg")],
    parentEnvironment: [
      "HOME": "/home", "PATH": "/bin", "RIPGREP_CONFIG_PATH": "/wrong", "LANG": "ja",
    ], isExecutableFile: { _ in executable })
}

private actor RipgrepProcessSpy: ProcessRunning {
  struct Call: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
    let outputLimit: Int
  }
  private(set) var calls: [Call] = []
  private var results: [Result<ProcessRunResult, ProcessRunnerError>]

  init(results: [Result<ProcessRunResult, ProcessRunnerError>]) {
    self.results = results
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) throws(ProcessRunnerError) -> ProcessRunResult {
    calls.append(
      .init(
        arguments: arguments, environment: environment, timeout: timeout, outputLimit: outputLimit))
    guard !results.isEmpty else { return ProcessRunResult(exitCode: 0, stdout: "", stderr: "") }
    return try results.removeFirst().get()
  }
}
