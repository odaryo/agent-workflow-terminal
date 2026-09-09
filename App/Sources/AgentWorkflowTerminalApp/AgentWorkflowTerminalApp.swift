import Adapters
import GhosttyRenderer
import SwiftUI
import TerminalCore

@main
struct AgentWorkflowTerminalApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel

  init() {
    _model = StateObject(wrappedValue: AppModel(dependencies: AppDependencies.make()))
  }

  var body: some Scene {
    // `WindowGroup` にしない。複製された window は同じ `AppModel` を共有するため、開いている
    // タブごとに `GhosttySurfaceView` が二重に生成され、同一 tmux session へ 2 client が
    // attach する。tmux は最小の client に合わせるので、小さい方が既存の表示を縮める。main
    // window の複製に意味を持たせるかは設計書 §25 で未確定であり、未確定のまま壊れた状態で
    // 開けるようにはしない (Issue #238)。
    Window("Agent Workflow Terminal", id: "main") {
      ProjectView(model: model)
        .frame(minWidth: 480, minHeight: 320)
    }
    .defaultSize(width: 900, height: 560)
    // `Window` だけで File メニューごと消えることは probe で観測済みで、この行は多重防御。
    // `WindowGroup` に戻して `.newItem` だけを外しても File メニューは同じく消えるため、
    // 「⌘N だけ消して ⌘W を残す」形はこの 2 つの組み合わせでは作れない (Issue #238 の計測)。
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

private struct ProjectView: View {
  @ObservedObject var model: AppModel
  @StateObject private var keyboardFocus = TerminalKeyboardFocus()

  var body: some View {
    VStack(spacing: 0) {
      if let warning = model.warning {
        WarningBar(text: warning) { model.dismissWarning() }
        Divider()
      }
      // 観測失敗を上と同じスロットへ載せない (`AppModel.scanFailureWarning`)。2本同時に出ても
      // 端末が潰れないのは、`WarningBar` がどちらも1行に丸めているためである。
      if let scanFailureWarning = model.scanFailureWarning {
        WarningBar(text: scanFailureWarning) { model.dismissScanFailureWarning() }
        Divider()
      }
      if model.projectRoot != nil || !model.worktrees.isEmpty {
        HStack(spacing: 0) {
          ScrollView(.horizontal) {
            // `LazyHStack` にしない。Active タブの代表状態は画面外でも観測し続ける必要があり
            // (Needs Attention を色で知らせる)、lazy にすると観測の有無がスクロール位置で
            // 変わる。対象が Active だけに絞られたので、観測の数はタブの数を超えない。
            HStack(spacing: 4) {
              if let projectRoot = model.projectRoot {
                ProjectRootTab(selected: model.selectedIdentity == projectRoot.identity) {
                  model.selectProjectRoot()
                }
                if !model.tabbedWorktrees.isEmpty {
                  Divider().frame(height: 22).padding(.horizontal, 2)
                }
              }
              ForEach(model.tabbedWorktrees, id: \.identity) { worktree in
                WorktreeTab(
                  worktree: worktree,
                  selected: model.selectedIdentity == worktree.identity,
                  agentPaneStates: { model.agentPaneStates(of: worktree.identity) },
                  select: { model.select(worktree) },
                  setActivation: { model.setActivation($0, of: worktree.identity) }
                )
              }
            }
            .padding(6)
          }
          .scrollIndicators(.hidden)
          InactiveWorktreeMenu(
            worktrees: model.inactiveWorktrees,
            activate: { model.setActivation(.active, of: $0) }
          )
          ViewerDrawerToolbar(layout: $model.viewerDrawerLayout)
            .padding(.trailing, 6)
        }
        Divider()
      }

      if let message = model.message ?? model.emptyStateMessage {
        ContentUnavailableView(
          "Agent Workflow Terminal", systemImage: "exclamationmark.triangle",
          description: Text(message))
      } else {
        ViewerDrawerView(
          layout: $model.viewerDrawerLayout,
          worktree: model.selectedWorktree,
          diffModels: model.diffModels,
          mainPanes: model.mainPanes,
          agentPaneStates: model.agentPaneStates(of:),
          keyboardFocus: keyboardFocus
        ) {
          TerminalTabs(model: model, keyboardFocus: keyboardFocus)
        }
      }
    }
    .task { model.run() }
    .onChange(of: model.selectedIdentity) { _, _ in
      keyboardFocus.tabSelectionChanged(drawerLayout: model.viewerDrawerLayout)
    }
    .onChange(of: model.viewerDrawerLayout) { old, new in
      keyboardFocus.drawerLayoutChanged(from: old, to: new)
    }
  }
}

private struct WarningBar: View {
  let text: String
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
      Text(text).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      Button("閉じる", systemImage: "xmark", action: dismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.orange.opacity(0.15))
  }
}

private struct ViewerDrawerToolbar: View {
  @Binding var layout: ViewerDrawerLayout

  var body: some View {
    HStack(spacing: 4) {
      Menu("Viewer", systemImage: "sidebar.right") {
        ForEach(ViewerContent.allCases, id: \.self) { content in
          Button(content.toolbarTitle) { layout.openPrimary(content) }
        }
      }
      .menuStyle(.borderlessButton)

      if layout.isOpen {
        Menu("ペインを追加", systemImage: "rectangle.split.2x1") {
          ForEach(ViewerContent.allCases, id: \.self) { content in
            Button(content.toolbarTitle) { layout.openSecondary(content) }
          }
        }
        .menuStyle(.borderlessButton)

        Menu("表示方法", systemImage: "rectangle.on.rectangle") {
          Button("並べて表示") { layout.setPresentation(.inline) }
          Button("オーバーレイ") { layout.setPresentation(.overlay) }
          Button("フルスクリーン") { layout.setPresentation(.fullscreen) }
          Divider()
          Button("分割方向を切り替え") { layout.toggleSplitAxis() }
          Button("主と副を入れ替え") { layout.swapPanes() }
            .disabled(layout.secondary == nil)
        }
        .menuStyle(.borderlessButton)

        Button("Viewer を閉じる", systemImage: "xmark") { layout.closeAll() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
    }
  }
}

private extension ViewerContent {
  var toolbarTitle: String {
    switch self {
    case .code: "Code"
    case .diff: "Diff"
    case .evidence: "Evidence"
    }
  }
}

private struct TerminalTabs: View {
  @ObservedObject var model: AppModel
  @ObservedObject var keyboardFocus: TerminalKeyboardFocus

  var body: some View {
    ZStack {
      if let projectRoot = model.projectRoot,
        model.openedIdentities.contains(projectRoot.identity)
      {
        TerminalTabContent(
          worktree: projectRoot,
          sessions: model.sessions,
          focusRequest: focusRequest(for: projectRoot.identity)
        )
        .opacity(model.selectedIdentity == projectRoot.identity ? 1 : 0)
        .allowsHitTesting(model.selectedIdentity == projectRoot.identity)
      }
      ForEach(model.tabbedWorktrees, id: \.identity) { worktree in
        if model.openedIdentities.contains(worktree.identity) {
          TerminalTabContent(
            worktree: worktree.detected,
            sessions: model.sessions,
            focusRequest: focusRequest(for: worktree.identity)
          )
          .opacity(model.selectedIdentity == worktree.identity ? 1 : 0)
          .allowsHitTesting(model.selectedIdentity == worktree.identity)
        }
      }
    }
  }

  private func focusRequest(for identity: WorktreeIdentity) -> TerminalFocusRequest? {
    keyboardFocus.focusRequest(isTabSelected: model.selectedIdentity == identity)
  }
}

private struct ProjectRootTab: View {
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Project Root", systemImage: "shippingbox")
        .fontWeight(.medium)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }
}

/// Inactive worktree を Active にする導線 (設計書 §3.2)。**状態は出さない** — 状態を出すには
/// pane を観測する必要があり、Inactive をタブから外した目的そのものが失われる (Issue #237)。
private struct InactiveWorktreeMenu: View {
  let worktrees: [TaskWorktree]
  let activate: (WorktreeIdentity) -> Void

  var body: some View {
    if !worktrees.isEmpty {
      Menu("Inactive", systemImage: "tray") {
        ForEach(worktrees, id: \.identity) { worktree in
          Button(title(of: worktree)) { activate(worktree.identity) }
            // 到達不能・観測失敗の Active 化は設計書 §3.2 が認めていない (attach 先を
            // 確かめられていない)。`AppModel.setActivation` も拒否するので、押せる見た目に
            // しない。
            .disabled(!worktree.detected.isReachable)
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  private func title(of worktree: TaskWorktree) -> String {
    let name =
      worktree.detected.branch
      ?? URL(fileURLWithPath: worktree.detected.worktreePath).lastPathComponent
    // 「観測失敗」を「到達不能」と出さない。到達できないと確かめられていないものを断定して
    // 見せないため (設計書 §12.3 と同じ理由、Issue #243)。
    switch worktree.detected.observation {
    case .reachable: return name
    case .unreachable: return "\(name) (到達不能)"
    case .observationFailed: return "\(name) (観測失敗)"
    }
  }
}

private struct WorktreeTab: View {
  let worktree: TaskWorktree
  let selected: Bool
  /// `AppModel.paneStates` を直に受けない。観測の可否を判定する経路を1本にし、タブ側と
  /// ドロワー側で食い違わないようにするため (Issue #237)。
  let agentPaneStates: () -> AsyncStream<[PaneAgentState]>?
  let select: () -> Void
  let setActivation: (WorktreeActivation) -> Void
  @State private var representativeState: WorktreeRepresentativeState?

  var body: some View {
    // 到達不能な worktree には `contextMenu` 自体を付けない。設計書 §3.2 が Active 化を
    // 認めていない対象で、空のメニューを開かせないため。
    if worktree.detected.isReachable {
      tab.contextMenu {
        Button("Active にする") { setActivation(.active) }
          .disabled(worktree.activation == .active)
        Button("Inactive にする") { setActivation(.inactive) }
          .disabled(worktree.activation == .inactive)
      }
    } else {
      tab
    }
  }

  private var tab: some View {
    Button(action: select) {
      HStack(spacing: 6) {
        Circle().fill(stateColor).frame(width: 8, height: 8)
        Text(
          worktree.detected.branch
            ?? URL(fileURLWithPath: worktree.detected.worktreePath).lastPathComponent
        )
        .foregroundStyle(worktree.activation == .active ? Color.primary : Color.secondary)
        Text(stateLabel).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
      .clipShape(.rect(cornerRadius: 6))
      .overlay {
        if worktree.activation == .active {
          RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    // 到達不能な worktree は一覧から消さずに残す (設計書 §3.2)。消すと安定 ID が消失に見え、
    // 復帰したときにユーザーが意図した Active/Inactive が失われる。
    .disabled(!worktree.detected.isReachable)
    .opacity(worktree.detected.isReachable ? 1 : 0.4)
    .task(id: worktree.identity) {
      guard let paneStates = agentPaneStates() else { return }
      let states = WorktreeRepresentativeStateFeed().states(from: paneStates)
      for await state in states {
        representativeState = state
      }
    }
  }

  private var stateLabel: String {
    // 到達不能な worktree では pane を観測していない。`Idle` と出すと観測できていない状態を
    // 観測した状態に丸めることになる (設計書 §12.3 の `Unknown` と同じ理由)。
    // 「観測失敗」を「到達不能」と出さないのは、到達できないと確かめられていないものを
    // 断定して見せないためである (Issue #243)。
    switch worktree.detected.observation {
    case .unreachable: return "到達不能"
    case .observationFailed: return "観測失敗"
    case .reachable: break
    }
    guard let representativeState else { return "Idle" }
    return representativeState.state.displayLabel
  }

  private var stateColor: Color {
    // 観測できていないことを `Unknown` と同じ色で示す (設計書 §12.3)。
    if worktree.detected.observation == .observationFailed { return .orange }
    guard let representativeState else { return .secondary }
    return switch representativeState.category {
    case .needsAttention: .red
    case .readyForReview: .green
    case .working: .blue
    case .unknown: .orange
    case .idle: .secondary
    }
  }
}

private struct TerminalTabContent: View {
  let worktree: DetectedWorktree
  let sessions: TmuxSessionProvisioner?
  let focusRequest: TerminalFocusRequest?
  @State private var preparation = TerminalSessionPreparation.preparing
  /// attach の試行番号。**世代の識別子**であり、失敗の再試行回数ではない。
  /// `.task(id:)` を再走させる鍵と、覆う世代の突き合わせに使う。
  @State private var attempt = 0
  /// どの世代を覆うかの規則は `TerminalCore` が持つ。ここはその答えを表示へ配るだけ。
  @State private var exitObservation = TerminalExitObservation()

  var body: some View {
    Group {
      if sessions == nil {
        ContentUnavailableView("tmux を利用できません", systemImage: "terminal")
      } else {
        switch preparation {
        case .preparing:
          ProgressView("tmux session を用意しています")
        case .ready(let command):
          terminal(command: command, generation: attempt)
        case .failed(let reason):
          ContentUnavailableView(
            "tmux session を用意できません", systemImage: "exclamationmark.triangle",
            description: Text(reason))
        }
      }
    }
    // 1つの世代につき1回だけ走らせる。用意し直すと、その worktree の端末が動いている最中に
    // surface を作り替えることになる。世代が上がるのは、下の再 attach を押したときだけ。
    .task(id: TerminalSessionAttempt(identity: worktree.identity, attempt: attempt)) {
      guard let sessions, case .preparing = preparation else { return }
      let result = await sessions.attachCommand(
        for: worktree.identity, workingDirectory: worktree.worktreePath)
      // Why not 書いてしまう: cancel 後のこの task はもう古い世代のものであり、その結果で
      // 新しい世代の用意を上書きすると、表示と argv の世代が食い違う。
      guard !Task.isCancelled else { return }
      preparation =
        switch result {
        case .success(let command): .ready(command)
        case .failure(let error): .failed(error.terminalTabDescription)
        }
    }
  }

  // Why 引数で受ける: `attempt` を**値として**渡すため。closure の中で `attempt` を読むと、
  // `@State` は保存領域から現在値を返すので、通知が届いた時点の値になり、世代の
  // 突き合わせにならない。
  private func terminal(command: [String], generation: Int) -> some View {
    let hasExited = exitObservation.isExited(generation: generation)
    return ZStack {
      GhosttyTerminalView(
        command: command,
        workingDirectory: worktree.worktreePath,
        focusRequest: focusRequest,
        // プロセスが終わった端末にキーボードを持たせない。`focusRequest` を `nil` に
        // すり替える形では塞がらない — `nil` は「取りに行かない」だけで、既に別のタブの
        // 端末が持っている first responder を誰も降ろさないため、覆いを見ながらの打鍵が
        // 別 worktree の生きた session へ入る (Issue #234)。
        keyboardParticipation: hasExited ? .withdrawn : .normal,
        stateChanged: { state in exitObservation.observe(state, generation: generation) }
      )
      // 世代ごとに別の NSView にする。`GhosttySurfaceView` は `start()` の時点の argv を
      // 保持するので、使い回されると再 attach の新しい argv が効かない。加えて、非同期に
      // 届く状態通知が世代をまたがないことも、この `.id` が保証している。
      .id(generation)
      // 覆いが出ている間はマウスも端末へ通さない。SwiftUI の重ね順で足りるはずだが、実体は
      // hosting view の subview である AppKit の NSView なので、重ね順だけに頼らない。
      .allowsHitTesting(!hasExited)
      if hasExited { exitedOverlay }
    }
  }

  /// surface を**完全に覆う**。libghostty が `wait-after-command` で出す
  /// "Press any key to close the terminal." は、こちらからは消せず、押しても閉じない
  /// (閉じるかどうかは上位の判断で、`GhosttySurfaceView.handleCloseRequest` は意図的に
  /// 何もしない)。文言と挙動を一致させる手段は、その文言を操作対象から外すことだけである。
  ///
  /// - Important: **終わった理由は名乗らない。** 観測できるのは「端末のプロセスが終わった」
  ///   ことだけで、`detach` なのか最後の pane での `exit` なのかは区別できない
  ///   (どちらも client の終了状態は 0。隔離ソケットで実測、Issue #234)。前者では session が
  ///   残り、後者では session ごと消えて再 attach は新しい session を作る。区別できない
  ///   ものを断定して見せない (設計書 §12.3 の `Unknown` と同じ理由)。
  private var exitedOverlay: some View {
    VStack(spacing: 10) {
      Image(systemName: "bolt.horizontal.circle").font(.largeTitle)
      Text("この端末のプロセスが終了しました").font(.headline)
      Text(
        """
        tmux から detach したか、session が終了しています。再 attach すると session を\
        用意し直します — 残っていれば同じ session に、消えていれば新しい session になります。
        """
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      Button("再 attach") {
        // 世代を上げて `.task` を再走させる。`restart()` (同じ argv の再実行) では復帰しない
        // 場合がある — attach の argv は `-A` を持たないので、session が消えていると
        // `can't find session` で終わる (隔離ソケットで実測、Issue #234)。provisioner を
        // 通せば、残っていれば Resume、消えていれば §4.2 / §4.4 の保証付きで作り直しになる。
        attempt += 1
        preparation = .preparing
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // 不透明にする。半透明だと下の英文が透けて読め、押せない案内が押せるように見える。
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

/// `.task(id:)` の鍵。worktree が同じでも世代が変われば用意をやり直す。
private struct TerminalSessionAttempt: Equatable {
  let identity: WorktreeIdentity
  let attempt: Int
}

private enum TerminalSessionPreparation {
  case preparing
  /// surface へ渡す attach の argv。
  case ready([String])
  case failed(String)
}
