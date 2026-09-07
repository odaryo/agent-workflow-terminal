import Adapters
import Foundation
import SwiftUI
import TerminalCore

/// Viewer Drawer の `.diff` ペインの状態 (設計書 §9)。
///
/// worktree ごとに1つを使い回す。Drawer を閉じてもこのオブジェクトは `DiffViewerModelStore` が
/// 持ち続けるので、base branch の記憶 (§9.1.1) と過去 snapshot (§9.3) が失われない。
@MainActor
final class DiffViewerModel: ObservableObject {
  enum Kind: Hashable, CaseIterable {
    case commit
    case base
    case branch
  }

  struct FileSelection: Hashable {
    let origin: DiffChangeOrigin
    let path: String
  }

  /// 再観測の間隔。agent の編集は `.git/index` を触らないので index の監視では拾えず、
  /// かといって 4 本の git を高頻度で回すわけにもいかないため、明示 Refresh と併用する前提の
  /// 粗いポーリングにしてある (§9.3)。
  static let changeCheckInterval = Duration.seconds(5)
  private static let commitListLimit = 50

  let worktreeRoot: URL

  @Published var kind: Kind = .base
  @Published private(set) var baseBranch: DiffBaseBranch = .undetermined
  @Published private(set) var selectedBranch: String?
  @Published private(set) var selectedCommit: GitCommit?
  @Published private(set) var refNames: GitRefNames?
  @Published private(set) var commits: [GitCommit] = []
  /// 保持の不変条件は `DiffSnapshotHistory` が持つ (§9.3)。
  @Published private(set) var history = DiffSnapshotHistory()
  @Published var currentSnapshotID: DiffSnapshotID?
  @Published var selection: FileSelection?
  @Published private(set) var changeSinceOpened: DiffSnapshotComparison?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  /// 部分成功で落ちた分と、中身を読めなかった untracked。黙って捨てない。
  @Published private(set) var notices: [String] = []

  /// ユーザーが選び直した base branch。タスクタブごとに覚え、次に開いても再判定しない (§9.1.1)。
  private var userSelectedBaseBranch: String?
  private var didLoadContext = false

  init(worktreeRoot: URL) {
    self.worktreeRoot = worktreeRoot
  }

  var currentSnapshot: DiffSnapshot? {
    guard let currentSnapshotID else { return history.latest }
    return history.snapshot(currentSnapshotID)
  }

  var isViewingOldSnapshot: Bool {
    guard let current = currentSnapshot, let latest = history.latest else { return false }
    return current.id != latest.id
  }

  var baseBranchDescription: String {
    switch baseBranch {
    case .resolved(let branch, let source): "\(branch) (\(source.label))"
    case .undetermined: "未決定"
    }
  }

  /// #208 のコメント anchor が張る先。表示中の snapshot の行を読み取り専用で渡す。
  func anchors(for selection: FileSelection) -> [DiffLineAnchor] {
    currentSnapshot?.anchors(origin: selection.origin, path: selection.path) ?? []
  }

  // MARK: - 読み込み

  func loadContextIfNeeded() async {
    guard !didLoadContext else { return }
    didLoadContext = true
    await loadContext()
  }

  func loadContext() async {
    let outcome = await Self.readContext(
      worktreeRoot: worktreeRoot, userSelection: userSelectedBaseBranch)
    switch outcome {
    case .success(let context):
      baseBranch = context.baseBranch
      refNames = context.refNames
      commits = context.commits
      if selectedCommit == nil { selectedCommit = context.commits.first }
      if selectedBranch == nil { selectedBranch = context.baseBranch.branch }
      errorMessage = nil
    case .failure(let failure):
      errorMessage = failure.message
    }
  }

  func selectBaseBranch(_ branch: String) {
    userSelectedBaseBranch = branch
    baseBranch = DiffBaseBranchResolver.resolve(
      userSelection: branch, upstream: nil, originHead: nil)
  }

  func selectBranch(_ branch: String) {
    selectedBranch = branch
  }

  func selectCommit(_ commit: GitCommit) {
    selectedCommit = commit
  }

  /// Diff を開く / Refresh する。どちらも新しい snapshot を作り、古いものは残す (§9.3)。
  func openSnapshot() async {
    guard let request = currentRequest() else { return }
    isLoading = true
    defer { isLoading = false }
    let outcome = await Self.build(worktreeRoot: worktreeRoot, request: request)
    switch outcome {
    case .success(let result):
      history.append(result.snapshot)
      currentSnapshotID = result.snapshot.id
      changeSinceOpened = nil
      selection = firstSelection(in: result.snapshot)
      notices = Self.notices(for: result)
      errorMessage = nil
    case .failure(let failure):
      errorMessage = failure.message
    }
  }

  func checkForChanges() async {
    guard let opened = currentSnapshot, !isViewingOldSnapshot, let request = currentRequest() else {
      return
    }
    guard
      case .success(let observation) = await Self.observe(
        worktreeRoot: worktreeRoot, request: request)
    else { return }
    changeSinceOpened = DiffSnapshotChangeDetection.compare(
      opened: opened.observation, current: observation)
  }

  func setReviewState(_ state: DiffReviewState) {
    guard let id = currentSnapshot?.id else { return }
    history.setReviewState(state, for: id)
  }

  func showSnapshot(_ id: DiffSnapshotID) {
    currentSnapshotID = id
    selection = history.snapshot(id).flatMap(firstSelection(in:))
  }

  private func firstSelection(in snapshot: DiffSnapshot) -> FileSelection? {
    for section in snapshot.sections {
      if let file = section.files.first {
        return FileSelection(origin: section.origin, path: file.path)
      }
    }
    return nil
  }

  private func currentRequest() -> DiffRequest? {
    switch kind {
    case .commit:
      guard let commit = selectedCommit else { return nil }
      return .commit(hash: commit.hash, parentHashes: commit.parentHashes)
    case .base:
      guard let branch = baseBranch.branch else { return nil }
      return .base(branch: branch)
    case .branch:
      guard let branch = selectedBranch else { return nil }
      return .branch(name: branch)
    }
  }

  // MARK: - git 呼び出し

  private struct Context: Sendable {
    let baseBranch: DiffBaseBranch
    let refNames: GitRefNames
    let commits: [GitCommit]
  }

  /// Why not `Task.detached`: `WorktreeSearchModel` と同じ理由で、キャンセルを繋いだまま
  /// MainActor から降りるために `nonisolated` な async 関数を使う。
  nonisolated private static func readContext(
    worktreeRoot: URL, userSelection: String?
  ) async -> Result<Context, DiffViewerFailure> {
    let builder: DiffSnapshotBuilder
    do {
      builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
    } catch {
      return .failure(DiffViewerFailure(message: "git を利用できません: \(error)"))
    }
    do {
      return .success(
        Context(
          baseBranch: await builder.resolveBaseBranch(userSelection: userSelection),
          refNames: try await builder.refNames(),
          commits: try await builder.recentCommits(maxCount: commitListLimit)))
    } catch {
      return .failure(DiffViewerFailure(message: "Git 情報を取得できません: \(error)"))
    }
  }

  nonisolated private static func build(
    worktreeRoot: URL, request: DiffRequest
  ) async -> Result<DiffSnapshotBuildResult, DiffViewerFailure> {
    let builder: DiffSnapshotBuilder
    do {
      builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
    } catch {
      return .failure(DiffViewerFailure(message: "git を利用できません: \(error)"))
    }
    do {
      return .success(
        try await builder.build(request, id: DiffSnapshotID(rawValue: UUID()), now: Date()))
    } catch {
      return .failure(DiffViewerFailure(message: message(for: error)))
    }
  }

  nonisolated private static func observe(
    worktreeRoot: URL, request: DiffRequest
  ) async -> Result<DiffSnapshotObservation, DiffViewerFailure> {
    do {
      let builder = try DiffSnapshotBuilder(
        worktreeRoot: worktreeRoot, processRunner: FoundationProcessRunner())
      return .success(try await builder.observe(request))
    } catch {
      return .failure(DiffViewerFailure(message: "\(error)"))
    }
  }

  nonisolated private static func message(for error: DiffSnapshotBuilderError) -> String {
    switch error {
    case .unsupportedMergeCommit(let parents):
      // どの親と比べるかは設計書が定めていない (§9.1.2)。第一親を推測で選ばない。
      "merge commit の Diff は未対応です (親 \(parents.count) 件)"
    case .invalidRevision(let value):
      "revision を解決できません: \(value)"
    case .git(let error):
      "git の実行に失敗しました: \(error)"
    }
  }

  nonisolated private static func notices(for result: DiffSnapshotBuildResult) -> [String] {
    var notices: [String] = []
    if !result.patchFailures.isEmpty {
      notices.append("Diff の一部を解析できていません (\(result.patchFailures.count) 件)")
    }
    if !result.statusFailures.isEmpty {
      notices.append("status の一部を解析できていません (\(result.statusFailures.count) 件)")
    }
    if !result.unreadableUntrackedPaths.isEmpty {
      notices.append(
        "untracked の内容を読めていません (\(result.unreadableUntrackedPaths.count) 件)")
    }
    return notices
  }
}

struct DiffViewerFailure: Error {
  let message: String
}

/// worktree ごとの `DiffViewerModel` を Drawer の開閉より長く持たせるための入れ物。
@MainActor
final class DiffViewerModelStore: ObservableObject {
  private var models: [URL: DiffViewerModel] = [:]

  func model(for worktreeRoot: URL) -> DiffViewerModel {
    if let existing = models[worktreeRoot] { return existing }
    let model = DiffViewerModel(worktreeRoot: worktreeRoot)
    models[worktreeRoot] = model
    return model
  }
}

extension DiffBaseBranchSource {
  fileprivate var label: String {
    switch self {
    case .userSelection: "選択"
    case .upstream: "upstream"
    case .originHead: "origin/HEAD"
    }
  }
}
