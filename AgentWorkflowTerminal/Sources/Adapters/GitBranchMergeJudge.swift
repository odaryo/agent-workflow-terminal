import Foundation
import TerminalCore

/// Close の安全確認 (設計書 §3.4) と Overview のマージ済みの印 (Issue #879) が共有する、既定 branch の
/// 解決・先端の解決・merge 判定。2つの経路で「マージ済み」の定義が食い違わないよう、判定は
/// ここにしか置かない。
///
/// - Important: `runner` は replace ref と grafts を無効にしたもの (`ignoresHistoryRewrites`) を
///   渡す。効いたままだと未マージの branch をマージ済みと判定しうる (§3.4、Issue #384)。
struct GitBranchMergeJudge: Sendable {
  enum CommitResolution: Sendable {
    case resolved(CommitObjectID)
    case failed(GitCloseSafetyInspectionFailure.Reason)
  }

  let runner: GitRunner
  let squashScanCommitLimit: Int
  let mergeCache: GitBranchMergeCache?

  func resolveDefaultBranch(
    projectRootBranch: String?
  ) async -> DefaultBranchInspection {
    do {
      let output = try await runner.run(.originHead()).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let branch = Self.remoteBranchName(from: output) else {
        return .init(
          resolution: .unresolved(reason: .invalidOriginHead(output)), revision: nil,
          failures: [])
      }
      return .init(
        resolution: .originHead(branch: branch), revision: output, failures: [])
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      // --quiet の exit 1 は symbolic ref が無いという正常なフォールバック条件。
      guard let projectRootBranch else {
        return .init(
          resolution: .unresolved(reason: .originHeadMissing), revision: nil, failures: [])
      }
      return .init(
        resolution: .projectRoot(branch: projectRootBranch),
        revision: "refs/heads/\(projectRootBranch)",
        failures: [])
    } catch {
      return .init(
        resolution: .unresolved(reason: .lookupFailed),
        revision: nil,
        failures: [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  func resolveCommit(_ revision: GitRevision) async -> CommitResolution {
    let output: String
    do {
      output = try await runner.run(.resolveCommit(revision)).stdout
    } catch {
      return .failed(.git(error))
    }
    guard let tip = localBranchTip(from: output) else {
      return .failed(.invalidRevision(output))
    }
    return .resolved(tip)
  }

  /// 再利用の鍵は判定に使った2つの OID と走査上限 (`GitBranchMergeCache`、Issue #366)。
  func judge(
    tip: CommitObjectID, destination destinationTip: CommitObjectID
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    guard let target = GitRevision(tip.rawValue),
      let destination = GitRevision(destinationTip.rawValue)
    else {
      return (.unknown, [.init(check: .branchMerge, reason: .invalidRevision(tip.rawValue))])
    }
    let cacheKey = GitBranchMergeCache.Key(
      tip: tip, destination: destinationTip, squashScanCommitLimit: squashScanCommitLimit)
    if let cached = await mergeCache?.status(for: cacheKey) {
      return (cached, [])
    }
    let result = await judgeMerge(tip: tip, target: target, destination: destination)
    await mergeCache?.store(result.status, for: cacheKey)
    return result
  }

  private func judgeMerge(
    tip: CommitObjectID,
    target: GitRevision,
    destination: GitRevision
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    do {
      _ = try await runner.run(.isAncestor(target, of: destination))
      return (.merged(.ancestor, tip: tip), [])
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      return await inspectSquashMerge(tip: tip, target: target, destination: destination)
    } catch {
      return (.unknown, [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  /// ancestor 判定に現れない squash merge を、branch の合成差分と既定 branch 側 commit の差分の
  /// 同一性で拾う (§3.4)。検出漏れは「削除が提示されないだけ」なので `.unmerged` へ倒し、
  /// 走査を完遂できなかったときも `.merged` は返さない。
  ///
  /// 比較には `diffFileSummaries` の raw + numstat を使う。git 2.50.1 の実測で、squash merge 前に
  /// 既定 branch が**別のファイルを**変更していても、branch が触ったパスの前後 blob OID は
  /// 変わらないため両者の出力はバイト一致した。同じ実測で `git cherry` は 2 commit 以上の branch を
  /// 1 件も検出できず (全行が `+`)、`git patch-id` は引数のファイルを無視して stdin を待つため
  /// `ProcessRunning` (stdin を渡さない) からは使えない。
  ///
  /// **既定 branch が branch と同じファイルを触っていると検出できない** (安全側の `.unmerged`)。
  /// 前 image の blob OID が食い違うためで、実測では競合しない位置への変更でも外れた
  /// (`a52ef27→71b0298` に対し squash 側は `a28971b→81741c6`)。同じ入力で `patch-id --stable` は
  /// 一致したので、これは raw 比較に固有の取りこぼしである。並列レーン運用では main が同じ
  /// ファイルを触るのは日常なので、検出率はここで頭打ちになる。
  private func inspectSquashMerge(
    tip: CommitObjectID,
    target: GitRevision,
    destination: GitRevision
  ) async -> (status: BranchMergeStatus, failures: [GitCloseSafetyInspectionFailure]) {
    let mergeBaseOutput: String
    do {
      mergeBaseOutput = try await runner.run(.mergeBase(target, destination)).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch GitRunnerError.commandFailed(let exitCode, _, _) where exitCode == 1 {
      // 共通祖先が無いという**答え**であって異常ではない (git 2.50.1 / 2.55.0 で実測:
      // rc=1 / stdout 空 / stderr 空。不正な ref は rc=128、option の誤りは rc=129 なので
      // 取り違えない)。plain な `merge-base` の EXIT STATUS は man に無く、rc=1 の意味は
      // 契約ではなくこの 2 版での実測である。
      //
      // 共通祖先が無い branch も `--allow-unrelated-histories` を付ければ squash merge され得る
      // (実測: 取り込んだ内容が既定 branch に入る)。それでも合成差分の起点が無いのでこの手法では
      // 検出せず、安全側の `.unmerged` に倒す —— 検出漏れは削除が提示されないだけである。
      return (.unmerged, [])
    } catch {
      return (.unknown, [.init(check: .branchMerge, reason: .git(error))])
    }
    guard let mergeBase = GitRevision(mergeBaseOutput) else {
      return (
        .unknown, [.init(check: .branchMerge, reason: .invalidRevision(mergeBaseOutput))]
      )
    }
    do {
      let branchChange = try await changeSummary(from: mergeBase, to: target)
      // 内容差が空の branch は、既定 branch 側の空 commit と一致して `.merged` に化ける
      // (実測: `commit --allow-empty` を1つ持つ既定 branch に対して出力が両方とも空になった)。
      // commit そのものは既定 branch に無いので、これは「マージ済み」ではない。
      guard !branchChange.isEmpty else { return (.unmerged, []) }

      // `log` は新しい順なので、上限は「新しい方から何件見るか」になる。上限に達したら
      // そこで打ち切り、見つからなかったものとして `.unmerged` に落ちる。
      // `GitReadCommand.log` は 0 以下で `--max-count` を付けないため、上限 0 は
      // 「走査しない」ではなく「全件走査」になる (この型の既定は 300)。
      let log = GitLog.parse(
        output: try await runner.run(
          .log(
            range: .twoDot(from: mergeBase, to: destination),
            maxCount: squashScanCommitLimit)
        ).stdout)
      guard log.failures.isEmpty else {
        return (.unknown, [.init(check: .branchMerge, reason: .logParse(log.failures))])
      }

      for commit in log.commits {
        // 第1親との差 = その commit が既定 branch へ持ち込んだ変更。merge commit では第2親との差が
        // 「取り込まれた側から見た残り」になり、squash 相当かどうかの問いに答えない。
        // 親を持たない commit は無関係な履歴の root で、既定 branch へ何を持ち込んだかを
        // この式では書けないので飛ばす —— 飛ばした結果は「一致しなかった」= `.unmerged` 側。
        guard let parentHash = commit.parentHashes.first,
          let parent = GitRevision(parentHash),
          let commitRevision = GitRevision(commit.hash)
        else { continue }
        if try await changeSummary(from: parent, to: commitRevision) == branchChange {
          return (.merged(.squash, tip: tip), [])
        }
      }
      return (.unmerged, [])
    } catch {
      return (.unknown, [.init(check: .branchMerge, reason: .git(error))])
    }
  }

  private func changeSummary(
    from: GitRevision, to: GitRevision
  ) async throws(GitRunnerError) -> String {
    try await runner.run(.diffFileSummaries(.range(.twoDot(from: from, to: to)))).stdout
  }

  private static func remoteBranchName(from revision: String) -> String? {
    let prefix = "refs/remotes/"
    guard revision.hasPrefix(prefix) else { return nil }
    let remoteAndBranch = revision.dropFirst(prefix.count)
    guard let separator = remoteAndBranch.firstIndex(of: "/") else { return nil }
    let remote = remoteAndBranch[..<separator]
    let branch = remoteAndBranch[remoteAndBranch.index(after: separator)...]
    guard !remote.isEmpty, !branch.isEmpty else { return nil }
    return String(branch)
  }

  struct DefaultBranchInspection: Sendable {
    let resolution: DefaultBranchResolution
    let revision: String?
    let failures: [GitCloseSafetyInspectionFailure]
  }
}
