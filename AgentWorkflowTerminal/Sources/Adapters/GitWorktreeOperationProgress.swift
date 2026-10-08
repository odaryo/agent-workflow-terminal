import Foundation
import TerminalCore

/// 途中状態を表す pseudo ref。値は git の ref 名そのもの。
enum GitInProgressReference: String, Sendable, CaseIterable {
  case mergeHead = "MERGE_HEAD"
  case cherryPickHead = "CHERRY_PICK_HEAD"
  case revertHead = "REVERT_HEAD"

  var operation: WorktreeInProgressOperation {
    switch self {
    case .mergeHead: .merge
    case .cherryPickHead: .cherryPick
    case .revertHead: .revert
    }
  }
}

extension GitReadCommand {
  /// detached HEAD では rc=1 で何も出さない (`--quiet`。git 2.50.1 実測)。rc=128 の失敗と
  /// 区別できるので、detached を失敗へ混ぜずに答えられる。
  static func headReference() -> Self {
    Self(arguments: ["symbolic-ref", "--quiet", "HEAD"])
  }

  /// 無ければ rc=1、repository として開けなければ rc=128 (git 2.50.1 実測)。
  static func verifyReference(_ reference: GitInProgressReference) -> Self {
    Self(arguments: ["rev-parse", "--verify", "--quiet", reference.rawValue])
  }

  /// branch の先端を完全な OID で返す (`localBranchTip(from:)` で読む)。git 2.50.1 実測:
  /// 管理ディレクトリで撃っても `refs/heads/` は共有なので同じ値を返し、ref が無ければ rc=1、
  /// SHA-256 の repository では 64 桁を返した。
  static func resolveCommit(_ revision: GitRevision) -> Self {
    Self(arguments: ["rev-parse", "--verify", "--quiet", revision.rawValue])
  }
}

/// `resolveCommit` の出力 (OID 1行) を読む。読めなければ `nil`。
func localBranchTip(from output: String) -> CommitObjectID? {
  CommitObjectID(output.hasSuffix("\n") ? String(output.dropLast()) : output)
}

/// `refs/heads/` は全 worktree で共有なので、`runner` は管理ディレクトリで動くものでも
/// Project Root で動くものでもよい。
func readLocalBranchTip(
  _ branch: String, with runner: GitRunner
) async throws(GitWorktreeProgressReadError) -> CommitObjectID {
  guard let revision = localBranchRevision(branch) else { throw .invalidBranchName(branch) }
  let output: String
  do {
    output = try await runner.run(.resolveCommit(revision)).stdout
  } catch {
    throw .git(error)
  }
  guard let tip = localBranchTip(from: output) else { throw .unexpectedTipOutput(output) }
  return tip
}

/// 短縮 local branch 名を、`GitCloseSafetyInspector` が merge 判定で問うのと同じ ref にする。
func localBranchRevision(_ branch: String) -> GitRevision? {
  GitRevision("refs/heads/\(branch)")
}

public enum GitWorktreeProgressReadError: Error, Sendable, Equatable {
  case git(GitRunnerError)
  /// `symbolic-ref` が rc=0 で、ref 名1行として読めない出力を返した。
  case unexpectedHeadOutput(String)
  /// branch 名から問い合わせる ref を組めなかった (`GitRevision` が受け付けない値)。
  case invalidBranchName(String)
  /// `rev-parse` が rc=0 で、完全な OID 1行として読めない出力を返した。
  case unexpectedTipOutput(String)
}

/// Close の拒否条件 (設計書 §3.4) —— HEAD が branch を指しているかと作業途中か —— を読む。
///
/// **git は対象 worktree の管理ディレクトリ (`WorktreeIdentity`) で動かす。** git 2.50.1 実測では、
/// `git -C <common>/worktrees/<名前>` は作業ツリーで動かしたときと同じ worktree の HEAD と
/// pseudo ref を答えた。作業ツリーのパスで動かさないのは、答えが安定 ID に結び付くからである ——
/// 作業ツリーのディレクトリが無くなっても読め、管理ディレクトリが無くなれば rc=128 で失敗する。
///
/// 観測手段の選び方 (Issue #355、git 2.50.1 実測):
///
/// - `status --porcelain=v2` は使わない。merge・cherry-pick・revert の衝突はどれも同じ `u UU` 行に
///   なって種類が分からず、clean な bisect と、衝突を解決した後の連続 cherry-pick は1行も出さない。
///   種類を出す long 形式の `status` は人間向けの文言で、parse する対象ではない。
/// - `MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD` はファイルの有無ではなく git に問う。
///   reftable 形式の repository (`init --ref-format=reftable`) では `CHERRY_PICK_HEAD` と
///   `REVERT_HEAD` が ref store に入り、管理ディレクトリにファイルとして現れない
///   (`MERGE_HEAD` はファイルのまま)。`rev-parse --verify` はどちらの形式でも rc=0 を返した。
/// - `rebase-merge` / `rebase-apply` / `BISECT_LOG` / `sequencer` は ref ではないので、管理
///   ディレクトリの下のファイルの有無で見る。reftable 形式でも同じ場所に置かれた。
struct GitWorktreeProgressReader: Sendable {
  enum Head: Sendable, Equatable {
    /// `refs/heads/` を除いた値。`GitWorktreeDetector` が `DetectedWorktree.branch` を作るのと
    /// 同じ規則で、`refs/heads/` が付かない値は加工しない。
    case branch(String)
    case detached
  }

  private static let branchRefPrefix = "refs/heads/"

  private let runner: GitRunner
  private let administrativeDirectory: String
  private let fileExists: @Sendable (String) -> Bool

  /// `runner` は `identity` のパスで動くものを渡す。
  init(
    runner: GitRunner, identity: WorktreeIdentity, fileExists: @escaping @Sendable (String) -> Bool
  ) {
    self.runner = runner
    self.administrativeDirectory = identity.rawValue
    self.fileExists = fileExists
  }

  func head() async throws(GitWorktreeProgressReadError) -> Head {
    let output: String
    do {
      output = try await runner.run(.headReference()).stdout
    } catch .commandFailed(exitCode: 1, _, _) {
      return .detached
    } catch {
      throw .git(error)
    }
    let reference = output.hasSuffix("\n") ? String(output.dropLast()) : output
    guard !reference.isEmpty, !reference.contains("\n") else {
      throw .unexpectedHeadOutput(output)
    }
    guard reference.hasPrefix(Self.branchRefPrefix) else { return .branch(reference) }
    return .branch(String(reference.dropFirst(Self.branchRefPrefix.count)))
  }

  func operations() async throws(GitWorktreeProgressReadError) -> Set<WorktreeInProgressOperation> {
    var operations: Set<WorktreeInProgressOperation> = []
    // ファイルがあれば、git が ref として読めなくても途中とみなす。git 2.50.1 実測: 衝突中の
    // `MERGE_HEAD` / `CHERRY_PICK_HEAD` を空や `garbage` に書き換えると `rev-parse --verify` は
    // rc=1 (= 無い) を返すが、`git status` は `You have unmerged paths.` のままだった。
    // reftable 形式では `CHERRY_PICK_HEAD` / `REVERT_HEAD` がファイルにならないので git にも問う。
    for reference in GitInProgressReference.allCases {
      let present = exists(reference.rawValue) ? true : try await exists(reference)
      guard present else { continue }
      operations.insert(reference.operation)
    }
    if exists("rebase-merge") {
      operations.insert(.rebase)
    }
    // `git am` と `rebase --apply` は同じディレクトリを使い、`am` だけが `applying` を置く
    // (git 2.50.1 実測: `rebase --apply` の側には `rebasing` がある)。
    if exists("rebase-apply") {
      operations.insert(exists("rebase-apply/applying") ? .mailboxApply : .rebase)
    }
    if exists("BISECT_LOG") {
      operations.insert(.bisect)
    }
    // 衝突中の連続 cherry-pick は `CHERRY_PICK_HEAD` と `sequencer` を両方持つ。種類がもう
    // 分かっているときに `.sequence` を重ねると、UI が同じ操作を2つ並べることになる。
    if exists("sequencer"), operations.isDisjoint(with: [.cherryPick, .revert]) {
      operations.insert(.sequence)
    }
    return operations
  }

  func tip(ofBranch branch: String) async throws(GitWorktreeProgressReadError) -> CommitObjectID {
    try await readLocalBranchTip(branch, with: runner)
  }

  private func exists(
    _ reference: GitInProgressReference
  ) async throws(GitWorktreeProgressReadError) -> Bool {
    do {
      _ = try await runner.run(.verifyReference(reference))
      return true
    } catch .commandFailed(exitCode: 1, _, _) {
      return false
    } catch {
      throw .git(error)
    }
  }

  private func exists(_ name: String) -> Bool {
    fileExists(administrativeDirectory + "/" + name)
  }
}

/// 実行直前の読み直しで Close を中止した理由 (設計書 §3.4、Issue #354)。
///
/// 計画段階の拒否 (`WorktreeClosePlanError`) を、session 終了の直前にもう一度判定した結果である。
/// 計画から実行までの間に Agent が rebase を始めた場合や、保存から復元した陳腐化した branch で
/// 計画を作った場合に、detached HEAD の worktree が消えるのを止める —— detached には
/// `worktree remove` が `--force` 無しでも成功し、積んだ commit は gc 後に失われる (git 2.50.1 実測)。
/// HEAD と途中状態は、読み直しから worktree 削除までの窓を残存リスクとして受け入れている。先端は
/// `branch -D` の直前にもう一度確かめる (`WorktreeCloseStepFailure.Reason.branchTipMoved`)。
public enum WorktreeClosePreflightRefusal: Sendable, Equatable {
  case detachedHead
  /// HEAD が計画時 (`WorktreeClosePlan.branch`) と別の branch を指している。`current` は
  /// `refs/heads/` を除いた値。
  case branchChanged(planned: String, current: String)
  case operationInProgress(Set<WorktreeInProgressOperation>)
  /// branch の先端がマージ判定のとき (`WorktreeCloseStep.deleteBranch` の `tip`) から動いた。
  /// 判定の後に積まれた commit はマージ済みと確かめられておらず、`branch -D` はそれごと消す。
  /// branch 削除を含む計画でだけ問う。
  case branchTipMoved(planned: CommitObjectID, current: CommitObjectID)
  /// 読み直せなかった。確かめられない以上、実行しない側へ倒す。
  case observationFailed(GitWorktreeProgressReadError)
}

extension GitWorktreeProgressReader {
  /// branch 名はバイト列で比べる (`WorktreeIdentity` と同じ理由。`String` の `==` は正準等価な
  /// 別表記を等しいと答える)。HEAD を先に読むのは、停止中の rebase では HEAD が detach しており
  /// (git 2.50.1 実測)、計画段階と同じ `detachedHead` を返すためである。
  ///
  /// `plannedTip` は branch 削除を含む計画でだけ渡す。先端を読むのは HEAD が計画どおりの branch を
  /// 指していると確かめた後なので、読むのは計画時と同じ名前の branch である。
  func preflightRefusal(
    plannedBranch: String, plannedTip: CommitObjectID?
  ) async -> WorktreeClosePreflightRefusal? {
    do {
      guard case .branch(let current) = try await head() else { return .detachedHead }
      guard current.utf8.elementsEqual(plannedBranch.utf8) else {
        return .branchChanged(planned: plannedBranch, current: current)
      }
      let inProgress = try await operations()
      guard inProgress.isEmpty else { return .operationInProgress(inProgress) }
      guard let plannedTip else { return nil }
      let currentTip = try await tip(ofBranch: plannedBranch)
      return currentTip == plannedTip
        ? nil : .branchTipMoved(planned: plannedTip, current: currentTip)
    } catch {
      return .observationFailed(error)
    }
  }
}

public struct GitWorktreeProgressInspectionResult: Sendable, Equatable {
  public let report: WorktreeOperationProgressReport
  /// `report.progress` が `.unknown` になった理由。
  public let failure: GitWorktreeProgressReadError?
}

/// `planWorktreeClose` が要求する途中状態の観測 (設計書 §3.4、Issue #355) を作る。
public struct GitWorktreeProgressInspector: Sendable {
  private let target: DetectedWorktree
  private let reader: GitWorktreeProgressReader

  public init(
    target: DetectedWorktree,
    processRunner: any ProcessRunning,
    executableCandidates: [URL] = GitRunner.defaultExecutableCandidates
  ) throws(GitRunnerError) {
    self.init(
      target: target,
      runner: try GitRunner(
        repositoryDirectory: URL(fileURLWithPath: target.identity.rawValue),
        processRunner: processRunner, executableCandidates: executableCandidates),
      fileExists: { FileManager.default.fileExists(atPath: $0) })
  }

  init(
    target: DetectedWorktree, runner: GitRunner,
    fileExists: @escaping @Sendable (String) -> Bool
  ) {
    self.target = target
    self.reader = GitWorktreeProgressReader(
      runner: runner, identity: target.identity, fileExists: fileExists)
  }

  public func inspect() async -> GitWorktreeProgressInspectionResult {
    do {
      let operations = try await reader.operations()
      return .init(
        report: .init(target: target, progress: .observed(operations)), failure: nil)
    } catch {
      return .init(report: .init(target: target, progress: .unknown), failure: error)
    }
  }
}
