import Adapters
import Foundation
import TerminalCore

/// Commit Diff の比較元の表示に要る値。`GitCommit` を丸ごと持たないのは、App の外で
/// 初期化できない型をテストから作れないため。
struct DiffCommitLabel: Equatable {
  let abbreviatedHash: String
  let subject: String
  let parentCount: Int

  init(abbreviatedHash: String, subject: String, parentCount: Int) {
    self.abbreviatedHash = abbreviatedHash
    self.subject = subject
    self.parentCount = parentCount
  }

  init(_ commit: GitCommit) {
    self.init(
      abbreviatedHash: commit.abbreviatedHash, subject: commit.subject,
      parentCount: commit.parentHashes.count)
  }
}

/// snapshot を開いた時点で App 側だけが知っている範囲の値 (§9.1)。git の観測値 (HEAD・
/// merge-base・出所ごとのファイル) は `DiffSnapshot` が持つ。開く操作の**前に**取り込み、
/// git の実行中にユーザーが選択を変えても、作った snapshot と食い違わないようにする。
struct DiffSnapshotRangeContext: Equatable {
  let worktreeName: String
  /// Base Diff だけが持つ。
  let baseSource: DiffBaseBranchSource?
  /// Commit Diff だけが持つ。
  let commit: DiffCommitLabel?
}

/// Diff pane の上部に出す範囲 (§9.1)。どの行も snapshot に記録した値だけから作り、開いた後の
/// HEAD の移動は反映しない — それは §9.3 の「変更あり」が伝える。
struct DiffRangeSummary: Equatable {
  /// OID の表示桁数。git の `%h` と違い衝突を避けて伸ばさないので、表示専用。
  static let abbreviatedObjectLength = 7

  let target: String
  let comparison: String
  let origin: String
  let contents: String

  init(snapshot: DiffSnapshot, context: DiffSnapshotRangeContext) {
    target = "\(context.worktreeName) — \(Self.headLabel(snapshot.head))"
    switch snapshot.subject {
    case .base(let branch, let mergeBase):
      let source = context.baseSource.map { " (\($0.decisionLabel))" } ?? ""
      comparison = "base \(branch)\(source)"
      origin = Self.mergeBaseLabel(mergeBase)
      contents = Self.worktreeContents(snapshot)
    case .branch(let name, let mergeBase):
      comparison = "branch \(name)"
      origin = Self.mergeBaseLabel(mergeBase)
      contents = Self.worktreeContents(snapshot)
    case .commit(let hash):
      let label = context.commit
      comparison =
        "commit \(label?.abbreviatedHash ?? Self.abbreviated(hash)) \(label?.subject ?? "")"
        .trimmingCharacters(in: .whitespaces)
      // merge commit は snapshot を作らない (`DiffSnapshotBuilderError.unsupportedMergeCommit`)
      // ので、ここへ来るのは親が 0 か 1 の commit だけ。
      origin = label?.parentCount == 0 ? "親の無い commit (空 tree)" : "その commit の親"
      let count = snapshot.section(.committed)?.files.count ?? 0
      contents = "その commit と親の差分 \(count) ファイル。未commit 変更は含まない"
    }
  }

  static func abbreviated(_ object: String) -> String {
    String(object.prefix(abbreviatedObjectLength))
  }

  private static func headLabel(_ head: DiffSnapshotHead?) -> String {
    guard let head else { return "HEAD を観測できませんでした" }
    let branch = head.branch.map { "branch \($0)" } ?? "detached"
    return "\(branch) @ \(abbreviated(head.object))"
  }

  private static func mergeBaseLabel(_ mergeBase: String) -> String {
    "merge-base \(abbreviated(mergeBase)) 起点"
  }

  /// §9.1.3 の5区分を、空の区分も 0 として必ず並べる。出ていない区分を「対象外」と
  /// 読まれないため。
  private static func worktreeContents(_ snapshot: DiffSnapshot) -> String {
    let counts = DiffChangeOrigin.allCases.map { origin in
      "\(origin.shortLabel) \(snapshot.section(origin)?.files.count ?? 0)"
    }
    return counts.joined(separator: "・") + " (ignored は含まない)"
  }
}

extension DiffChangeOrigin {
  fileprivate var shortLabel: String {
    switch self {
    case .unmerged: "競合"
    default: label
    }
  }
}

extension DiffBaseBranchSource {
  /// §9.1.1 のどの経路で base branch が決まったか。
  var decisionLabel: String {
    switch self {
    case .upstream: "upstream で決定"
    case .originHead: "origin/HEAD で決定"
    case .userSelection: "ユーザーが選択"
    }
  }
}

/// 比較先の候補に出す、同じ Project の他のタスク。`name` はタブと同じ名前で、branch の
/// あるタスクでは branch 名と同じになる。見分けの手がかりに worktree のディレクトリ名も持つ。
struct DiffComparisonTask: Equatable, Hashable {
  let name: String
  let branch: String
  let directory: String
}

/// Base / Branch の比較先メニューの区画 (他のタスク → local → remote)。
struct DiffComparisonCandidates: Equatable {
  let tasks: [DiffComparisonTask]
  let localBranches: [String]
  let remoteBranches: [String]

  /// 他のタスクの branch は local branch でもあるので、local の区画には重ねて出さない。
  init(tasks: [DiffComparisonTask], refNames: GitRefNames?, query: String) {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func matches(_ values: String...) -> Bool {
      needle.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
    let taskBranches = Set(tasks.map(\.branch))
    self.tasks = tasks.filter { matches($0.name, $0.branch, $0.directory) }
    localBranches = (refNames?.localBranches ?? []).filter {
      !taskBranches.contains($0) && matches($0)
    }
    remoteBranches = (refNames?.remoteBranches ?? []).filter { matches($0) }
  }

  var isEmpty: Bool { tasks.isEmpty && localBranches.isEmpty && remoteBranches.isEmpty }
}

/// Diff を開いている worktree の表示名と、比較先に出す他のタスク。`AppModel` の一覧から作る。
struct DiffWorktreeContext: Equatable {
  let displayName: String
  let otherTasks: [DiffComparisonTask]

  init(displayName: String, otherTasks: [DiffComparisonTask]) {
    self.displayName = displayName
    self.otherTasks = otherTasks
  }

  /// detached HEAD のタスクは branch 名で比較先にできないので候補に出さない。
  init(worktreeRoot: URL, projectRoot: DetectedWorktree?, worktrees: [TaskWorktree]) {
    let path = worktreeRoot.standardizedFileURL.path
    func isSelf(_ worktree: DetectedWorktree) -> Bool {
      URL(fileURLWithPath: worktree.worktreePath).standardizedFileURL.path == path
    }
    if let projectRoot, isSelf(projectRoot) {
      displayName = "Project Root"
    } else if let own = worktrees.first(where: { isSelf($0.detected) }) {
      displayName = own.detected.tabName
    } else {
      displayName = worktreeRoot.lastPathComponent
    }
    otherTasks = worktrees.compactMap { worktree in
      guard worktree.activation == .active, !isSelf(worktree.detected),
        let branch = worktree.detected.branch
      else { return nil }
      return DiffComparisonTask(
        name: worktree.detected.tabName, branch: branch,
        directory: URL(fileURLWithPath: worktree.detected.worktreePath).lastPathComponent)
    }
  }
}
