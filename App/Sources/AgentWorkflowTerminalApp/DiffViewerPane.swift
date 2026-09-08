import Adapters
import SwiftUI
import TerminalCore

/// Viewer Drawer の `.diff` ペイン (設計書 §9)。
struct DiffViewerPane: View {
  @ObservedObject var model: DiffViewerModel
  @ObservedObject var mainPane: MainPaneCoordinator
  let worktree: WorktreeIdentity
  /// Agent と判定された pane を候補一覧の**印**にするためだけの観測 (§12.7)。Project Root の
  /// ように観測経路が無ければ `nil` で、その場合は印の無い候補一覧になる。
  let agentPaneStates: () -> AsyncStream<[PaneAgentState]>?
  let keyboardFocus: TerminalKeyboardFocus

  /// 候補一覧の Agent 印 (§12.7) と、送信可否の判定 (§9.2.2) の両方に使う最後の観測。
  @State private var paneStates: [PaneAgentState] = []
  /// 観測経路そのものがあるか。空配列 (経路はあるが Agent pane が無い) と区別して
  /// §9.2.2 の文言を変えるために持つ。
  @State private var isObservingPanes = false

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      banners
      // HSplitView は VStack の中では余った縦を自分から取りに行かない (実測: 上下に空きが出る)。
      // 明示的に優先度を上げて、残りの高さをこのペインへ渡す。
      content
        .layoutPriority(1)
    }
    .task { await model.loadContextIfNeeded() }
    .task {
      // Drawer を閉じるとこのビューが階層から外れ、`task` ごと監視が止まる。
      while !Task.isCancelled {
        try? await Task.sleep(for: DiffViewerModel.changeCheckInterval)
        guard !Task.isCancelled else { return }
        await model.checkForChanges()
      }
    }
    .task {
      guard let states = agentPaneStates() else { return }
      isObservingPanes = true
      for await panes in states {
        paneStates = panes
      }
    }
    .sheet(item: $model.paneSelectionRequest) { request in
      MainPanePicker(request: request) { candidate in
        Task {
          await model.choose(
            candidate, for: request, mainPane: mainPane, agentPaneStates: observedPaneStates)
        }
      } cancel: {
        model.paneSelectionRequest = nil
      }
    }
  }

  // MARK: - 操作

  @ViewBuilder
  private var controls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("種別", selection: $model.kind) {
          Text("Commit").tag(DiffViewerModel.Kind.commit)
          Text("Base").tag(DiffViewerModel.Kind.base)
          Text("Branch").tag(DiffViewerModel.Kind.branch)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Button(model.currentSnapshot == nil ? "開く" : "Refresh", systemImage: "arrow.clockwise") {
          Task { await model.openSnapshot() }
        }
        .disabled(model.isLoading)
      }
      subjectSelector
      if let snapshot = model.currentSnapshot {
        HStack {
          Picker("レビュー状態", selection: reviewStateBinding(snapshot)) {
            Text("Reviewing").tag(DiffReviewState.reviewing)
            Text("Reviewed").tag(DiffReviewState.reviewed)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 200)
          if model.history.count > 1 {
            snapshotHistoryMenu
          }
          Spacer()
        }
        sendControls
      }
    }
    .padding(8)
  }

  /// 登録済みの送信先を見せ、いつでも選び直せるようにする (§12.7)。
  @ViewBuilder
  private var sendControls: some View {
    HStack(spacing: 8) {
      Text(destinationLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("送信先を選ぶ") {
        Task {
          await model.requestMainPaneSelection(
            worktree: worktree, mainPane: mainPane, agentPaneStates: observedPaneStates)
        }
      }
      .buttonStyle(.link)
      .disabled(model.isSending)
      Spacer()
      Button("Review batch を送信 (\(model.currentSnapshotComments.count))") {
        Task {
          await model.requestSend(
            .batch(model.currentSnapshotComments.map(\.id)),
            worktree: worktree, mainPane: mainPane, agentPaneStates: observedPaneStates)
        }
      }
      .disabled(model.currentSnapshotComments.isEmpty || model.isSending || sendBlock != nil)
    }
  }

  /// `nil` は観測経路が無いこと。到達不能な worktree などで、pane のせいにしないための区別。
  private var observedPaneStates: [PaneAgentState]? { isObservingPanes ? paneStates : nil }

  /// 状態で送信操作を無効にする理由 (§9.2.2)。判定は `DiffCommentSendGate` の1箇所に閉じる。
  private var sendBlock: DiffCommentSendBlock? {
    model.sendBlock(
      registeredPane: mainPane.registeredPane(for: worktree), agentPaneStates: observedPaneStates)
  }

  private var destinationLabel: String {
    guard let pane = mainPane.registeredPane(for: worktree) else { return "送信先: 未登録" }
    return "送信先: pane \(pane.rawValue)"
  }

  private func reviewStateBinding(_ snapshot: DiffSnapshot) -> Binding<DiffReviewState> {
    Binding(get: { snapshot.reviewState }, set: { model.setReviewState($0) })
  }

  @ViewBuilder
  private var subjectSelector: some View {
    switch model.kind {
    case .base:
      HStack {
        Text("base: \(model.baseBranchDescription)")
          .font(.caption)
        branchMenu(title: "選び直す") { model.selectBaseBranch($0) }
        Spacer()
      }
    case .branch:
      HStack {
        Text("比較先: \(model.selectedBranch ?? "未選択")")
          .font(.caption)
        branchMenu(title: "選ぶ") { model.selectBranch($0) }
        Spacer()
      }
    case .commit:
      HStack {
        Text(model.selectedCommit.map { "\($0.abbreviatedHash) \($0.subject)" } ?? "未選択")
          .font(.caption)
          .lineLimit(1)
        Menu("選ぶ") {
          ForEach(model.commits, id: \.hash) { commit in
            Button("\(commit.abbreviatedHash) \(commit.subject)") { model.selectCommit(commit) }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        Spacer()
      }
    }
  }

  private func branchMenu(title: String, action: @escaping (String) -> Void) -> some View {
    Menu(title) {
      ForEach(model.refNames?.all ?? [], id: \.self) { name in
        Button(name) { action(name) }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var snapshotHistoryMenu: some View {
    Menu("履歴 (\(model.history.count))") {
      ForEach(model.history.snapshots.reversed(), id: \.id) { snapshot in
        Button(Self.snapshotLabel(snapshot)) { model.showSnapshot(snapshot.id) }
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private static func snapshotLabel(_ snapshot: DiffSnapshot) -> String {
    let time = snapshot.createdAt.formatted(date: .omitted, time: .standard)
    let state = snapshot.reviewState == .reviewed ? "Reviewed" : "Reviewing"
    return "\(time) — \(state)"
  }

  // MARK: - 通知

  @ViewBuilder
  private var banners: some View {
    VStack(alignment: .leading, spacing: 2) {
      if case .undetermined = model.baseBranch, model.kind == .base {
        banner("base branch を判定できません。選び直してください。", icon: "questionmark.circle")
      }
      if let error = model.errorMessage {
        banner(error, icon: "exclamationmark.triangle")
      }
      if model.isViewingOldSnapshot {
        banner("過去の snapshot を表示しています。", icon: "clock.arrow.circlepath")
      }
      if let comparison = model.changeSinceOpened, comparison.hasChanges {
        banner(Self.changeMessage(comparison), icon: "exclamationmark.arrow.circlepath")
      }
      if model.changeSinceOpened?.head == .unknown {
        banner("HEAD を観測できず、変更の有無を判断できません。", icon: "questionmark.circle")
      }
      ForEach(model.notices, id: \.self) { notice in
        banner(notice, icon: "exclamationmark.triangle")
      }
      if let block = sendBlock, let pane = mainPane.registeredPane(for: worktree) {
        banner(DiffViewerModel.message(for: block, pane: pane), icon: "pause.circle")
      }
      if let error = model.commentError {
        banner(error, icon: "exclamationmark.octagon")
      }
      if let report = model.sendReport {
        banner(report, icon: "doc.on.clipboard")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func changeMessage(_ comparison: DiffSnapshotComparison) -> String {
    let paths = comparison.changedPaths
    let head = comparison.head == .changed ? " (HEAD も動いています)" : ""
    guard !paths.isEmpty else { return "この Diff を開いてから HEAD が動いています。" }
    return "この Diff を開いてから \(paths.count) 件のファイルが変更されています\(head)"
  }

  private func banner(_ message: String, icon: String) -> some View {
    Label(message, systemImage: icon)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
  }

  // MARK: - 本体

  @ViewBuilder
  private var content: some View {
    if let snapshot = model.currentSnapshot {
      // Why not HSplitView: VStack の中に置くと縦に伸びず、ペイン下部に空きが出る (実測)。
      // 幅の調整より、Drawer いっぱいに差分が出ることを優先する。
      HStack(spacing: 0) {
        DiffFileList(model: model, snapshot: snapshot)
          .frame(width: 240)
        Divider()
        DiffHunkView(model: model, file: selectedFile(in: snapshot))
          .frame(minWidth: 200, maxWidth: .infinity)
        Divider()
        DiffCommentPanel(
          model: model, mainPane: mainPane, worktree: worktree,
          keyboardFocus: keyboardFocus
        ) {
          observedPaneStates
        }
        .frame(width: 260)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.isLoading {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView(
        "Diff", systemImage: "arrow.left.arrow.right",
        description: Text("種別と比較先を選んで「開く」を押すと、その時点で固定した Diff を表示します。")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func selectedFile(in snapshot: DiffSnapshot) -> UnifiedDiffFile? {
    guard let selection = model.selection else { return nil }
    return snapshot.file(origin: selection.origin, path: selection.path)
  }
}

private struct DiffFileList: View {
  @ObservedObject var model: DiffViewerModel
  let snapshot: DiffSnapshot

  var body: some View {
    List {
      ForEach(snapshot.sections.filter { !$0.files.isEmpty }, id: \.origin) { section in
        Section(header: Text("\(section.origin.label) (\(section.files.count))")) {
          ForEach(section.files, id: \.path) { file in
            row(origin: section.origin, file: file)
          }
        }
      }
      if snapshot.isEmpty {
        Text("差分はありません").font(.caption).foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
  }

  // Why not onTapGesture: Section を持つ List では行の tap が拾われず、選択が変わらなかった (実測)。
  private func row(origin: DiffChangeOrigin, file: UnifiedDiffFile) -> some View {
    let selection = DiffViewerModel.FileSelection(origin: origin, path: file.path)
    return Button {
      model.selection = selection
    } label: {
      HStack(spacing: 4) {
        Text(file.changeKind.badge)
          .font(.caption2.monospaced())
          .foregroundStyle(file.changeKind.badgeColor)
        Text(file.path)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(model.selection == selection ? Color.accentColor.opacity(0.18) : Color.clear)
  }
}

extension DiffChangeOrigin {
  var label: String {
    switch self {
    case .committed: "commit済み"
    case .staged: "staged"
    case .unstaged: "unstaged"
    case .untracked: "untracked"
    }
  }
}

extension UnifiedDiffChangeKind {
  fileprivate var badge: String {
    switch self {
    case .added: "A"
    case .deleted: "D"
    case .modified: "M"
    case .renamed: "R"
    case .copied: "C"
    }
  }

  fileprivate var badgeColor: Color {
    switch self {
    case .deleted: .red
    case .added: .green
    default: .blue
    }
  }
}
