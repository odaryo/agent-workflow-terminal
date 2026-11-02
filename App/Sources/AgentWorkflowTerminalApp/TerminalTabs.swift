import Adapters
import AppKit
import GhosttyRenderer
import SwiftUI
import TerminalCore

struct TerminalTabs: View {
  @ObservedObject var model: AppModel
  @ObservedObject var keyboardFocus: TerminalKeyboardFocus

  var body: some View {
    ZStack {
      ForEach(model.tabKeys, id: \.self) { key in
        if model.openedTabs.contains(key), let worktree = directory(for: key) {
          TerminalTabContent(
            key: key,
            worktree: worktree,
            sessions: model.sessions,
            shouldOpen: { await model.shouldOpenTab(key) },
            approveCreation: { model.approveSessionCreation(key) },
            didPrepare: { model.didPrepareTab(key) },
            didExit: { await model.handleTabExit(key) },
            focusRequest: keyboardFocus.focusRequest(isTabSelected: model.selectedTab == key)
          )
          .opacity(model.selectedTab == key ? 1 : 0)
          .allowsHitTesting(model.selectedTab == key)
        }
      }
    }
  }

  private func directory(for key: TerminalSessionKey) -> DetectedWorktree? {
    if let projectRoot = model.projectRoot, projectRoot.identity == key.identity {
      return projectRoot
    }
    return model.tabbedWorktrees.first { $0.identity == key.identity }?.detected
  }
}

private struct TerminalTabContent: View {
  let key: TerminalSessionKey
  let worktree: DetectedWorktree
  let sessions: TmuxSessionProvisioner?
  let shouldOpen: @MainActor () async -> TerminalTabOpening
  let approveCreation: @MainActor () -> Void
  let didPrepare: @MainActor () -> Void
  let didExit: @MainActor () async -> Void
  let focusRequest: TerminalFocusRequest?
  @State private var preparation = TerminalSessionPreparation.preparing
  /// attach の試行番号。**世代の識別子**であり、失敗の再試行回数ではない。
  /// `.task(id:)` を再走させる鍵と、覆う世代の突き合わせに使う。
  @State private var attempt = 0
  /// どの世代を覆うかの規則は `TerminalCore` が持つ。ここはその答えを表示へ配るだけ。
  @State private var exitObservation = TerminalExitObservation()
  @State private var handledExitGeneration: Int?

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
        case .missing:
          ContentUnavailableView {
            Label("前回の tmux session が見つかりません", systemImage: "bolt.horizontal.circle")
          } description: {
            Text(
              """
              このタブの session は、アプリを止めていた間に終了したか、確かめられませんでした。\
              中で動いていた Agent は戻りません。\
              新しい session を作るには、下のボタンを押してください。
              """
            )
          } actions: {
            Button("新しい session を作る") {
              approveCreation()
              attempt += 1
              preparation = .preparing
            }
          }
        case .failed(let reason):
          ContentUnavailableView {
            Label("tmux session を用意できません", systemImage: "exclamationmark.triangle")
          } description: {
            Text(reason)
          } actions: {
            Button("再試行") {
              // `preparation` だけを戻しても `.task(id:)` の鍵が変わらず再走しない。
              attempt += 1
              preparation = .preparing
            }
          }
        }
      }
    }
    // 1つの世代につき1回だけ走らせる。用意し直すと、その worktree の端末が動いている最中に
    // surface を作り替えることになる。世代が上がるのは、再試行か再 attach を押したときだけ。
    .task(id: TerminalSessionAttempt(key: key, attempt: attempt)) {
      guard let sessions, case .preparing = preparation else { return }
      let opening = await shouldOpen()
      guard !Task.isCancelled else { return }
      switch opening {
      case .open:
        break
      case .offerCreate:
        preparation = .missing
        return
      case .close:
        return
      }
      let result = await sessions.attachCommand(
        for: key, workingDirectory: worktree.worktreePath)
      // Why not 書いてしまう: cancel 後のこの task はもう古い世代のものであり、その結果で
      // 新しい世代の用意を上書きすると、表示と argv の世代が食い違う。
      guard !Task.isCancelled else { return }
      if case .success = result { didPrepare() }
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
        configurationFileURL: terminalConfigurationFileURL,
        focusRequest: focusRequest,
        // プロセスが終わった端末にキーボードを持たせない。`focusRequest` を `nil` に
        // すり替える形では塞がらない — `nil` は「取りに行かない」だけで、既に別のタブの
        // 端末が持っている first responder を誰も降ろさないため、覆いを見ながらの打鍵が
        // 別 worktree の生きた session へ入る (Issue #234)。
        keyboardParticipation: hasExited ? .withdrawn : .normal,
        stateChanged: { state in
          guard generation == attempt else { return }
          exitObservation.observe(state, generation: generation)
          if state == .exited, handledExitGeneration != generation {
            handledExitGeneration = generation
            Task { await didExit() }
          }
        }
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
  ///   残り、後者では session ごと消える。session が消えていれば、再 attach はこのディレクトリの
  ///   最後のタブだけ新しい session を作り、それ以外はタブを閉じる。区別できない
  ///   ものを断定して見せない (設計書 §12.3 の `Unknown` と同じ理由)。
  private var exitedOverlay: some View {
    VStack(spacing: 10) {
      Image(systemName: "bolt.horizontal.circle").font(.largeTitle)
      Text("この端末のプロセスが終了しました").font(.headline)
      Text(
        """
        tmux から detach したか、session が終了しています。再 attach すると、session が残っていれば\
        同じ session に繋ぎ直します。消えていれば、このディレクトリの最後のタブなら新しい session を作り、\
        そうでなければタブを閉じます。
        """
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      Button("再 attach") {
        // 世代を上げて `.task` を再走させる。`restart()` (同じ argv の再実行) では復帰しない
        // 場合がある — attach の argv は `-A` を持たないので、session が消えていると
        // `can't find session` で終わる (隔離ソケットで実測、Issue #234)。
        // 再準備では、session が消えていれば最後のタブだけ provisioner を通して
        // §4.2 / §4.4 の保証付きで作り直し、それ以外はタブを閉じる。
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
  let key: TerminalSessionKey
  let attempt: Int
}

private enum TerminalSessionPreparation {
  case preparing
  case missing
  /// surface へ渡す attach の argv。
  case ready([String])
  case failed(String)
}
