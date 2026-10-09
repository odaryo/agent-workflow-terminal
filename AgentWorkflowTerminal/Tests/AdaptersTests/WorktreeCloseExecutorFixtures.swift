import Foundation
import TerminalCore
import Testing

@testable import Adapters

/// **新しく git / tmux 呼び出しを足したら、その1回について timeout と子プロセス環境を固定する。**
/// Round 11・12・13 で3回続けて、新設した呼び出しだけが未固定のまま残った。`arguments` を見る
/// テストは代わりにならない (`arguments.last` の検査は timeout の変異を落とさない)。環境は
/// `LC_ALL=C` と `HOME` / `PATH` だけを通す —— `HOME` は `core.excludesFile` 経由で
/// 「何が ignored か」、つまり `--force` 無しで消えるものを変えるので、落としてはいけない。
/// **`outputLimit` はこの規約の外にある** (stub が記録もしない)。足すのは Issue #139 で
/// `WorktreeCloseExecutorTests` を分割するとき。
func expectFixedGitInvocation(
  _ invocation: WorktreeCloseGitStub.Invocation,
  timeout: Duration,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    invocation.environment == ["LC_ALL": "C", "HOME": "/home/tester", "PATH": "/usr/bin"],
    sourceLocation: sourceLocation)
  #expect(invocation.timeout == timeout, sourceLocation: sourceLocation)
}

/// `LC_ALL` が上書きされ、`GIT_DIR` と `LANG` が落ちることを確かめるための親環境。
let pollutedParentEnvironment = [
  "HOME": "/home/tester", "PATH": "/usr/bin", "LC_ALL": "ja_JP.UTF-8",
  "GIT_DIR": "/elsewhere/.git", "LANG": "ja_JP.UTF-8",
]

let removalRefusedStderr =
  "fatal: '/repo/wt' contains modified or untracked files, use --force to delete it\n"

func refusedRemovalGitStub() -> WorktreeCloseGitStub {
  gitStub(
    removeWorktree: .init(exitCode: 128, stdout: "", stderr: removalRefusedStderr),
    worktreeList: .init(exitCode: 0, stdout: worktreeListOutput(), stderr: ""))
}

let listedHead = String(repeating: "e1", count: 20)
let listedTargetAttributes = ["HEAD \(listedHead)", "branch refs/heads/topic"]
let prunableAttribute = "prunable gitdir file points to non-existent location"

/// `worktree list --porcelain -z` の出力。属性は `\0` 区切りで、record 間は空の属性で区切られる。
/// `targetPath` が `nil` なら対象の record を置かない。生の出力は各テストの doc に写してある。
func worktreeListOutput(
  targetPath: String? = "/repo/wt", targetAttributes: [String] = listedTargetAttributes
) -> String {
  var output = "worktree /repo\0HEAD \(listedHead)\0branch refs/heads/main\0\0"
  guard let targetPath else { return output }
  output += "worktree \(targetPath)\0" + targetAttributes.map { $0 + "\0" }.joined() + "\0"
  return output
}

func gitArgv(_ rest: String...) -> [String] {
  ["--no-optional-locks", "-C", "/repo", "--no-pager"] + rest
}

let gitSuccess = ProcessRunResult(exitCode: 0, stdout: "", stderr: "")

/// `symbolic-ref --quiet HEAD` が branch を指しているときの出力。
func headOnBranch(_ branch: String) -> ProcessRunResult {
  ProcessRunResult(exitCode: 0, stdout: "refs/heads/\(branch)\n", stderr: "")
}

/// detached HEAD と、`rev-parse --verify --quiet` が ref を見つけられないときの答え
/// (git 2.50.1 実測: どちらも rc=1 で出力なし)。
let gitNotFound = ProcessRunResult(exitCode: 1, stdout: "", stderr: "")

/// 検査がマージ判定に使ったことにする先端。`gitStub` の既定の `tip` もこれを返す。
let fixtureTipHex = String(repeating: "a", count: 40)
/// merge 判定で既定 branch の ref を解決した先端。branch 側 (`fixtureTipHex`) と取り違えないよう別の値にする。
let fixtureDefaultTipHex = String(repeating: "b", count: 40)

func inspectedTip() throws -> CommitObjectID {
  try #require(CommitObjectID(fixtureTipHex))
}

func merged(_ evidence: BranchMergeEvidence) throws -> BranchMergeStatus {
  .merged(evidence, tip: try inspectedTip())
}

/// `rev-parse --verify --quiet refs/heads/<branch>` が先端を返したときの出力。
func tipOutput(_ hex: String) -> ProcessRunResult {
  ProcessRunResult(exitCode: 0, stdout: hex + "\n", stderr: "")
}

/// 実行直前の読み直しの既定は「topic を指し、途中の作業は無く、先端は判定時のまま」。分岐を引数ごとに明示するのは、
/// 一致しない argv を `deleteBranch` の結果へ落とすと、読み直しの呼び出しが書き込みの stub を
/// 黙って借りるため。どれにも当たらない argv は rc=99 で返し、テストを落とす。
func gitStub(
  removeWorktree: ProcessRunResult = gitSuccess, worktreeList: ProcessRunResult = gitSuccess,
  deleteBranch: ProcessRunResult = gitSuccess, head: ProcessRunResult = headOnBranch("topic"),
  references: [String: ProcessRunResult] = [:], tip: ProcessRunResult = tipOutput(fixtureTipHex),
  tipBeforeDeletion: ProcessRunResult? = nil
) -> WorktreeCloseGitStub {
  WorktreeCloseGitStub { arguments in
    if arguments.contains("symbolic-ref") { return head }
    if arguments.contains("rev-parse") {
      let reference = arguments.last ?? ""
      guard reference.hasPrefix("refs/heads/") else { return references[reference] ?? gitNotFound }
      // `branch -D` の直前の読み直しは `repositoryDirectory` (`/repo`) で撃つ。
      return arguments.starts(with: gitArgv()) ? tipBeforeDeletion ?? tip : tip
    }
    if arguments.contains("remove") { return removeWorktree }
    if arguments.contains("list") { return worktreeList }
    if arguments.contains("branch") { return deleteBranch }
    return ProcessRunResult(exitCode: 99, stdout: "", stderr: "unexpected git invocation\n")
  }
}

extension WorktreeCloseExecution {
  var outcome: WorktreeCloseOutcome? {
    guard case .executed(let outcome) = self else { return nil }
    return outcome
  }

  var refusal: WorktreeClosePreflightRefusal? {
    guard case .abandoned(let refusal) = self else { return nil }
    return refusal
  }
}

struct WorktreeCloseHarness {
  let tmux: TmuxSessionRunnerStub
  let git: WorktreeCloseGitStub
  let worktree: DetectedWorktree
  let executor: WorktreeCloseExecutor

  init(
    tmux: TmuxSessionRunnerStub = .init(result: stubSuccess()),
    git: WorktreeCloseGitStub = gitStub(),
    repositoryDirectory: URL = URL(fileURLWithPath: "/repo"),
    identity: String = "/repo/.git/worktrees/feature-a", worktreePath: String = "/repo/wt",
    parentEnvironment: [String: String] = [:], existingFiles: Set<String> = []
  ) throws {
    let worktree = try Self.detected(identity: identity, worktreePath: worktreePath)
    self.tmux = tmux
    self.git = git
    self.worktree = worktree
    self.executor = try WorktreeCloseExecutor(
      repositoryDirectory: repositoryDirectory, worktree: worktree,
      sessionOperations: TmuxSessionOperations(
        runner: try TmuxRunner(
          socketName: "awt-test", processRunner: tmux,
          executableCandidates: [URL(fileURLWithPath: "/test/bin/tmux")], parentEnvironment: [:],
          isExecutableFile: { _ in true })),
      processRunner: git, executableCandidates: [URL(fileURLWithPath: "/test/bin/git")],
      parentEnvironment: parentEnvironment, isExecutableFile: { _ in true },
      fileExists: { existingFiles.contains($0) })
  }

  /// 実行直前の読み直しで中止されたら落とす。中止を検証するテストは `executor.execute` を直に呼ぶ。
  func run(_ plan: WorktreeClosePlan) async throws -> WorktreeCloseOutcome {
    try #require(try await executor.execute(plan).outcome)
  }

  func plan(
    _ choice: WorktreeCloseChoice, worktree: DetectedWorktree? = nil,
    uncommitted: UncommittedChangesStatus = .absent, merge: BranchMergeStatus = .unmerged,
    continuation: WorktreeRemovalConfirmation.Continuation = .withoutForce,
    progress: WorktreeOperationProgress = .observed([])
  ) throws -> WorktreeClosePlan {
    let wt = worktree ?? self.worktree
    let ci = WorktreeCloseInspection(
      uncommittedChanges: uncommitted, ignoredFiles: .absent, unpushedCommits: .absent,
      branchMerge: merge)
    let db = DefaultBranchResolution.originHead(branch: "main")
    let rp: WorktreeCloseInspectionReport = .init(target: wt, inspection: ci, defaultBranch: db)
    return try planWorktreeClose(
      worktree: wt, progress: .init(target: wt, progress: progress), choice: choice,
      confirmation: .init(report: rp, continuation: continuation))
  }

  static func detected(
    identity: String = "/repo/.git/worktrees/feature-a", worktreePath: String = "/repo/wt",
    branch: String? = "topic"
  ) throws -> DetectedWorktree {
    DetectedWorktree(
      identity: try #require(WorktreeIdentity(rawValue: identity)), worktreePath: worktreePath,
      branch: branch, isProjectRoot: false)
  }
}

actor WorktreeCloseGitStub: ProcessRunning {
  struct Invocation: Sendable, Equatable {
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
  }

  private let handler: @Sendable ([String]) -> ProcessRunResult
  private(set) var invocations: [Invocation] = []

  var arguments: [[String]] { invocations.map(\.arguments) }
  /// `repositoryDirectory` (`/repo`) で撃った呼び出し —— 書き込みと、失敗後の登録の読み直し。
  var repositoryInvocations: [Invocation] {
    invocations.filter { $0.arguments.starts(with: gitArgv()) }
  }
  /// 実行直前の読み直し。対象の管理ディレクトリで動くので `-C` の値が違う。
  var preflightInvocations: [Invocation] {
    invocations.filter { !$0.arguments.starts(with: gitArgv()) }
  }

  init(handler: @escaping @Sendable ([String]) -> ProcessRunResult) {
    self.handler = handler
  }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String], timeout: Duration,
    outputLimit: Int
  ) -> ProcessRunResult {
    invocations.append(.init(arguments: arguments, environment: environment, timeout: timeout))
    return handler(arguments)
  }
}
