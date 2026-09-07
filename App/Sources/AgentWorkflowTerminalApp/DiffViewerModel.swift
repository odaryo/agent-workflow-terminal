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

  /// コメントを付ける対象として選ばれている行 (§9.2)。単一行も1行の範囲として持つ。
  struct LineSelection: Equatable {
    let file: FileSelection
    let side: DiffLineSide
    var range: DiffLineRange
  }

  enum PendingSend: Equatable {
    case single(DiffReviewCommentID)
    case batch([DiffReviewCommentID])
  }

  /// 未登録・登録先の消失のどちらでも、送る前にユーザーへ選ばせるための要求 (§12.7)。
  struct PaneSelectionRequest: Identifiable {
    let id = UUID()
    let worktree: WorktreeIdentity
    let candidates: [MainPaneCandidate]
    /// 登録が残っているが、その pane が今は存在しない場合だけ入る。
    let missingPane: PaneID?
    /// 送信操作の途中で選ばせている場合だけ入る。`nil` は送信先の選び直しだけを行う操作。
    let pending: PendingSend?
  }

  /// 再観測の間隔。agent の編集は `.git/index` を触らないので index の監視では拾えず、
  /// かといって 4 本の git を高頻度で回すわけにもいかないため、明示 Refresh と併用する前提の
  /// 粗いポーリングにしてある (§9.3)。
  static let changeCheckInterval = Duration.seconds(5)
  static let commitListLimit = 50

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
  @Published var selection: FileSelection? {
    didSet {
      guard selection != oldValue else { return }
      lineSelection = nil
    }
  }
  /// 再起動を跨いだ永続化は Issue #208 の対象外なので、この worktree のコメントは
  /// プロセスが生きている間だけ残る。
  @Published private(set) var comments = DiffReviewComments()
  @Published private(set) var lineSelection: LineSelection?
  @Published var commentDraft = ""
  @Published private(set) var isSending = false
  /// 送信の結果。**貼り付けた**ことしか言わない (§9.2.1 制約1)。
  @Published private(set) var sendReport: String?
  /// 拒否・失敗。理由ごとに文言を変え、「送信できませんでした」へ丸めない。
  @Published private(set) var commentError: String?
  @Published var paneSelectionRequest: PaneSelectionRequest?
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

  // MARK: - 行選択とコメント (§9.2)

  var currentFileComments: [DiffReviewComment] {
    guard let snapshot = currentSnapshot, let selection else { return [] }
    return comments.comments(in: snapshot.id, origin: selection.origin, path: selection.path)
  }

  var currentSnapshotComments: [DiffReviewComment] {
    guard let snapshot = currentSnapshot else { return [] }
    return comments.comments(in: snapshot.id)
  }

  func isSelected(line: Int, side: DiffLineSide) -> Bool {
    guard let lineSelection, lineSelection.side == side, lineSelection.file == selection else {
      return false
    }
    return lineSelection.range.lineNumbers.contains(line)
  }

  func selectLine(_ line: Int, side: DiffLineSide) {
    guard let selection, let range = DiffLineRange(line: line) else { return }
    lineSelection = LineSelection(file: selection, side: side, range: range)
    commentError = nil
  }

  /// 既存の選択と同じ側の行までを範囲にする。側が違う行 (追加行と削除行) はまたげないので、
  /// その場合は単一行の選択として置き換える。
  func extendSelection(to line: Int, side: DiffLineSide) {
    guard let current = lineSelection, current.side == side, current.file == selection else {
      selectLine(line, side: side)
      return
    }
    let start = min(current.range.start, line)
    let end = max(current.range.end, line)
    guard let range = DiffLineRange(start: start, end: end) else { return }
    lineSelection = LineSelection(file: current.file, side: side, range: range)
    commentError = nil
  }

  func clearLineSelection() {
    lineSelection = nil
  }

  /// anchor を作れなかった場合 (選んだ範囲にその側の行が揃っていない等) はコメントを作らない。
  /// §9.2 の anchor は snapshot 上に実在する行からしか作れない。
  func addComment(now: Date = Date()) {
    guard let snapshot = currentSnapshot, let lineSelection else {
      commentError = "コメントを付ける行を選んでください。"
      return
    }
    guard !commentDraft.isEmpty else {
      commentError = "コメント本文が空です。"
      return
    }
    guard
      let anchor = snapshot.commentAnchor(
        origin: lineSelection.file.origin,
        path: lineSelection.file.path,
        side: lineSelection.side,
        lines: lineSelection.range)
    else {
      commentError = "選んだ範囲に \(lineSelection.side == .old ? "old" : "new") 側の行が揃っていません。"
      return
    }
    comments.add(
      DiffReviewComment(
        id: DiffReviewCommentID(rawValue: UUID()), anchor: anchor, body: commentDraft,
        createdAt: now))
    commentDraft = ""
    commentError = nil
    sendReport = nil
  }

  func removeComment(_ id: DiffReviewCommentID) {
    comments.remove(id)
  }

  func dismissMessages() {
    commentError = nil
    sendReport = nil
  }

  // MARK: - 送信 (§9.2 / §12.7)

  /// 送信先が未登録、または登録先が消えていれば `paneSelectionRequest` を立てて選ばせる。
  /// 候補が1つでも自動では選ばない (§12.7 確定)。
  func requestSend(
    _ pending: PendingSend,
    worktree: WorktreeIdentity,
    mainPane: MainPaneCoordinator,
    agentPaneIDs: Set<PaneID>
  ) async {
    guard !isSending else { return }
    dismissMessages()
    switch await mainPane.resolve(for: worktree, agentPaneIDs: agentPaneIDs) {
    case .failure(let failure):
      commentError = failure.message
    case .success(.registered(let pane, _)):
      await send(pending, to: pane, worktree: worktree, mainPane: mainPane)
    case .success(.unregistered(let candidates)):
      paneSelectionRequest = PaneSelectionRequest(
        worktree: worktree, candidates: candidates, missingPane: nil, pending: pending)
    case .success(.registeredPaneMissing(let pane, let candidates)):
      paneSelectionRequest = PaneSelectionRequest(
        worktree: worktree, candidates: candidates, missingPane: pane, pending: pending)
    }
  }

  /// 送信を伴わない選び直し (§12.7「ユーザーはいつでも選び直せる」)。
  func requestMainPaneSelection(
    worktree: WorktreeIdentity,
    mainPane: MainPaneCoordinator,
    agentPaneIDs: Set<PaneID>
  ) async {
    dismissMessages()
    switch await mainPane.resolve(for: worktree, agentPaneIDs: agentPaneIDs) {
    case .failure(let failure):
      commentError = failure.message
    case .success(let resolution):
      paneSelectionRequest = PaneSelectionRequest(
        worktree: worktree,
        candidates: resolution.candidates,
        missingPane: resolution.missingPane,
        pending: nil)
    }
  }

  /// 選ばれた pane を登録し、送信操作の途中だったならそのまま送る。
  func choose(
    _ pane: PaneID, for request: PaneSelectionRequest, mainPane: MainPaneCoordinator
  ) async {
    guard let pending = request.pending else {
      mainPane.register(pane, for: request.worktree)
      paneSelectionRequest = nil
      return
    }
    await send(pending, to: pane, worktree: request.worktree, mainPane: mainPane)
  }

  /// ユーザーが選んだ pane を記憶してから送る (§12.7)。以後はこの pane が既定の送信先になる。
  func send(
    _ pending: PendingSend,
    to pane: PaneID,
    worktree: WorktreeIdentity,
    mainPane: MainPaneCoordinator
  ) async {
    guard !isSending else { return }
    mainPane.register(pane, for: worktree)
    paneSelectionRequest = nil

    let targets: [DiffReviewComment]
    let text: String
    switch pending {
    case .single(let id):
      guard let comment = comments.comment(id) else {
        commentError = "送信するコメントが見つかりません。"
        return
      }
      targets = [comment]
      text = DiffReviewCommentMessage.text(for: comment)
    case .batch(let ids):
      targets = ids.compactMap { comments.comment($0) }
      guard !targets.isEmpty else {
        commentError = "送信するコメントがありません。"
        return
      }
      text = DiffReviewCommentMessage.batchText(for: targets)
    }

    isSending = true
    let outcome = await mainPane.inject(text, into: pane)
    isSending = false

    switch outcome {
    case .success:
      let now = Date()
      for comment in targets { comments.markSent(comment.id, at: now) }
      commentError = nil
      // 「Agent が受け取った」とは書かない。注入は貼り付けであって実行ではない (§9.2.1 制約1)。
      sendReport =
        "\(targets.count) 件を pane \(pane.rawValue) へ貼り付けました。"
        + "貼り付けであり、実行や Agent の受領は表しません。"
    case .failure(let failure):
      // コメントはローカルに残す (消さない)。
      sendReport = nil
      commentError = Self.message(for: failure)
    }
  }

  /// 拒否の理由ごとに文言を変える。`TmuxTextInjectionError` の分類はユーザーが取る復旧操作の
  /// 違いに対応しているため、まとめると復旧できない (`TmuxTextInjection` の doc 参照)。
  static func message(for failure: MainPaneInjectionFailure) -> String {
    switch failure {
    case .tmuxUnavailable:
      return "tmux を利用できないため送っていません。"
    case .rejected(let error):
      switch error {
      case .unsafeControlCharacter(let scalar, let offset):
        let code = String(format: "U+%04X", scalar.value)
        return
          "本文に貼り付けできない制御文字があります: 先頭から \(offset + 1) 番目の Unicode scalar が \(code)。"
          + "bracketed paste を抜け得るため送っていません。文面は自動修正しません。"
      case .paneInMode(let pane, let mode):
        let name = mode.isEmpty ? "(mode 名を読み直せませんでした。既に抜けた可能性があります)" : mode
        return
          "pane \(pane.rawValue) が \(name) 中のため送っていません (1バイトも届いていません)。"
          + "mode を抜けてから送り直してください。"
      case .paneInputDisabled(let pane):
        return
          "pane \(pane.rawValue) は入力が無効 (select-pane -d) のため送っていません "
          + "(1バイトも届いていません)。入力を有効に戻してください。"
      case .paneNotFound(let pane):
        return "pane \(pane.rawValue) が見つかりません。送信先を選び直してください。"
      case .invalidPaneID(let pane):
        return "pane ID の形式が不正です: \(pane.rawValue)"
      case .temporaryFileCreationFailed(let path):
        return "注入用の一時ファイルを作れませんでした: \(path)"
      case .tmux(let error):
        return "tmux の実行に失敗しました: \(error)"
      }
    }
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
