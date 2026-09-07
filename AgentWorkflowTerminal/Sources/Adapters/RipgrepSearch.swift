import Foundation
import TerminalCore

/// 検索の結果と、その結果がどこまで完全かの情報。「見つからなかった」と
/// 「調べられなかった」を1つの表示へ丸めないために、両者を分けて持つ (§12.3)。
public struct RipgrepSearchReport: Sendable {
  public let outcome: WorktreeSearchOutcome
  /// rg が探索を最後まで走らせたか。`--json` の `summary` イベントの有無で判定する。
  public let didFinish: Bool
  /// 読めなかったパス等、rg が stderr へ出した内容。空でなければ結果は網羅していない。
  public let warnings: String
  /// 解釈できなかった stdout の行。
  public let parseFailures: [RipgrepJSONLineFailure]
  /// worktree の外を指していたため捨てた結果の件数 (§8.1)。
  public let discardedOutOfScopeCount: Int
}

public struct RipgrepFileListReport: Sendable {
  public let paths: [WorktreeRelativePath]
  public let warnings: String
  public let discardedOutOfScopeCount: Int
}

public struct RipgrepSearch: Sendable {
  private let runner: RipgrepRunner

  public init(runner: RipgrepRunner) {
    self.runner = runner
  }

  public init(
    worktreeRoot: URL,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = RipgrepRunner.defaultExecutableCandidates
  ) throws(RipgrepRunnerError) {
    self.init(
      runner: try RipgrepRunner(
        worktreeRoot: worktreeRoot, processRunner: processRunner,
        executableCandidates: executableCandidates))
  }

  public func search(
    _ query: WorktreeSearchQuery,
    perFileLimit: Int = WorktreeSearchLimits.maximumMatchesPerFile,
    resultLimit: Int = WorktreeSearchLimits.maximumResultCount,
    timeout: Duration? = nil
  ) async throws(RipgrepRunnerError) -> RipgrepSearchReport {
    let result = try await runner.run(
      .search(query, worktreeRoot: runner.root, perFileLimit: perFileLimit), timeout: timeout,
      outputLimit: RipgrepRunner.searchOutputLimit)
    let parsed = RipgrepJSONOutputParser.parse(result.stdout, perFileLimit: perFileLimit)
    // 探索が始まってすらいない (不正な正規表現など) 場合だけをエラーにする。
    guard parsed.didFinish || result.exitCode <= 1 else {
      throw .commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }

    let root = runner.root.path
    var matches: [WorktreeSearchMatch] = []
    var discarded = 0
    for record in parsed.matches {
      guard
        let path = WorktreePathScope.relativePath(
          forAbsolutePath: record.absolutePath, underRoot: root),
        let line = RipgrepLineText.line(
          fromBytes: record.lineBytes, submatchByteRanges: record.submatchByteRanges),
        let match = WorktreeSearchMatch(
          path: path, lineNumber: record.lineNumber, line: line)
      else {
        discarded += 1
        continue
      }
      matches.append(match)
    }
    let truncatedFiles = parsed.filesReachingPerFileLimit.compactMap {
      WorktreePathScope.relativePath(forAbsolutePath: $0, underRoot: root)
    }

    return RipgrepSearchReport(
      outcome: .applyingResultLimit(
        to: matches, filesReachingPerFileLimit: truncatedFiles, limit: resultLimit),
      didFinish: parsed.didFinish, warnings: result.stderr, parseFailures: parsed.failures,
      discardedOutOfScopeCount: discarded)
  }

  public func listFiles(
    scope: WorktreeSearchScope,
    timeout: Duration? = nil
  ) async throws(RipgrepRunnerError) -> RipgrepFileListReport {
    let result = try await runner.run(
      .listFiles(scope: scope, worktreeRoot: runner.root), timeout: timeout,
      outputLimit: RipgrepRunner.searchOutputLimit)
    // `--files` には `summary` に相当する完了の印が無い。1件も出ていない失敗だけを
    // エラーにし、一部だけ読めた場合は警告として返す。
    guard result.exitCode <= 1 || !result.stdout.isEmpty else {
      throw .commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }

    let root = runner.root.path
    var paths: [WorktreeRelativePath] = []
    var discarded = 0
    for field in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
      guard
        let path = WorktreePathScope.relativePath(
          forAbsolutePath: String(field), underRoot: root)
      else {
        discarded += 1
        continue
      }
      paths.append(path)
    }
    return RipgrepFileListReport(
      paths: paths, warnings: result.stderr, discardedOutOfScopeCount: discarded)
  }
}
