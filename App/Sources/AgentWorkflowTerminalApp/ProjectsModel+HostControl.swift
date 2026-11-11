import Adapters
import Foundation
import TerminalCore

extension ProjectsModel {
  func startHostControl() async {
    guard hostControlServer == nil,
      let supportDirectory = dependencies.applicationSupportDirectory
    else { return }
    let applicationDirectory = supportDirectory.appending(
      path: WorktreeInventoryStore.applicationDirectoryName)
    let socketPath = applicationDirectory.appending(path: "hostctl.sock").path
    let server = HostControlSocketServer(path: socketPath)
    do {
      try FileManager.default.createDirectory(
        at: applicationDirectory, withIntermediateDirectories: true)
      try await server.start { [weak self] request in
        guard let self else {
          return .failure(code: .notRegistered, message: "アプリの窓口を利用できません")
        }
        if case .checkProject = request {
          // open の完了を待つと、hook の問い合わせ期限に間に合わない。
          return await self.handleHostControl(request)
        }
        return await self.enqueueHostControl(request)
      }
      hostControlServer = server
      // App Nap 中に CPU が混むと scan と応答が進まず、hostctl が 30 秒の期限に当たる (#868 で実測)。
      // userInitiated だけでは隠すと cpu / disk の絞りが残り、負荷時の応答が約 2.4 倍遅かった (#868 で実測)。
      hostControlActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "hostctl の要求に応答するため")
    } catch {
      let detail: String
      switch error as? HostControlSocketError {
      case .addressInUse: detail = "別のアプリがすでに hostctl の窓口を開いています"
      case .pathTooLong: detail = "socket のパスが長すぎます"
      default: detail = "hostctl の窓口を開けません"
      }
      warning = [warning, detail]
        .compactMap { $0 }.joined(separator: "\n")
      return
    }
    hostControlEnvironment.task = Task { [weak self] in
      while !Task.isCancelled {
        guard self != nil else { return }
        await self?.publishHostControlEnvironment(socketPath: socketPath)
        do {
          try await Task.sleep(for: .seconds(10))
        } catch {
          return
        }
      }
    }
  }

  private func enqueueHostControl(_ request: HostControlRequest) async -> HostControlResponse {
    let previous = pendingHostControl
    let task = Task {
      _ = await previous?.value
      let response = await handleHostControlWithDeadline(request)
      recordHandoffIfOpened(request, response)
      return response
    }
    pendingHostControl = task
    return await task.value
  }

  /// 期限切れや登録解除で差し替えた失敗は `.opened` にならないので、確定した応答だけを見る。
  /// `created == false` は既存セッションで、handoff.sh は指示を送らない。
  private func recordHandoffIfOpened(_ request: HostControlRequest, _ response: HostControlResponse)
  {
    guard case .openWorktree(_, let fromPane?, _) = request,
      case .opened(let opened) = response, opened.created
    else { return }
    for slot in slots.values {
      if case .available(let model) = slot, model.paneObservations.recordHandoff(fromPane) {
        return
      }
    }
  }

  private func handleHostControlWithDeadline(
    _ request: HostControlRequest
  ) async -> HostControlResponse {
    let timeout = HostControlResponse.failure(
      code: .tmuxFailed, message: "処理が時間内に終わりませんでした")
    let channel = AsyncStream<HostControlResponse>.makeStream(bufferingPolicy: .bufferingOldest(1))
    // キャンセルに応答しない処理の終了を待つと、期限を過ぎても後続要求へ進めない。
    let operation = Task {
      let response = await handleHostControl(request)
      channel.continuation.yield(response)
      channel.continuation.finish()
    }
    let timer = Task {
      do {
        try await Task.sleep(for: .seconds(25))
      } catch {
        return
      }
      channel.continuation.yield(timeout)
      channel.continuation.finish()
    }
    defer {
      operation.cancel()
      timer.cancel()
      channel.continuation.finish()
    }
    var iterator = channel.stream.makeAsyncIterator()
    return await iterator.next() ?? timeout
  }

  private func handleHostControl(_ request: HostControlRequest) async -> HostControlResponse {
    switch request {
    case .checkProject(let directory):
      switch await resolveHostControlProject(directory: directory) {
      case .available: return .projectRegistered
      case .failure(let response): return response
      }
    case .openWorktree(let directory, _, let purpose):
      let result = await resolveHostControlProject(
        directory: directory, rejectCancellation: true,
        beforeResolve: { hostControlPurposeFailure(purpose) })
      switch result {
      case .failure(let response): return response
      case .available(let project, let model):
        return await openWorktreeWithValidatedAgentCommand(
          agentCommand: project.agentCommand,
          open: { await model.openWorktreeForAgent(directory: directory, purpose: purpose) },
          isRegistered: { self.registry.project(project.commonDirectory) != nil })
      }
    }
  }

  private func resolveHostControlProject(
    directory: String, rejectCancellation: Bool = false,
    beforeResolve: () -> HostControlResponse? = { nil }
  ) async -> HostControlProjectLookup {
    guard directory.hasPrefix("/"), !directory.utf8.contains(0) else {
      return .failure(
        .failure(code: .invalidRequest, message: "directory は空でない絶対パスを指定してください"))
    }
    if let failure = beforeResolve() { return .failure(failure) }
    let project: RegisteredProject
    do {
      project = try await resolver.resolve(directory: URL(fileURLWithPath: directory))
    } catch GitProjectResolutionError.directoryUnreachable {
      return .failure(.failure(code: .unreachable, message: "worktree へ到達できません"))
    } catch {
      return .failure(.failure(code: .notRegistered, message: "登録済みの Project を解決できません"))
    }
    guard !rejectCancellation || !Task.isCancelled else {
      return .failure(.failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした"))
    }
    return hostControlProjectLookup(
      commonDirectory: project.commonDirectory, registry: registry, slots: slots)
  }

  private func publishHostControlEnvironment(socketPath: String) async {
    guard let runner = dependencies.tmuxRunner, let executable = dependencies.tmuxExecutable else {
      return
    }
    let sessions = TmuxSessionProvisioner(runner: runner, tmuxExecutable: executable)
    var environment = [("AWT_HOSTCTL_SOCKET", socketPath)]
    let hostctl = Bundle.main.bundleURL.appending(path: "Contents/MacOS/hostctl").path
    if FileManager.default.isExecutableFile(atPath: hostctl) {
      environment.append(("AWT_HOSTCTL", hostctl))
    }
    for (name, value) in environment {
      do {
        try await sessions.setGlobalEnvironment(name: name, value: value)
      } catch .serverNotRunning, .serverSocketMissing {
        continue
      } catch {
        NSLog("[app] hostctl の tmux 環境変数を設定できません: \(error)")
      }
    }
  }
}

enum HostControlProjectLookup {
  case available(RegisteredProject, AppModel)
  case failure(HostControlResponse)
}

func hostControlProjectLookup(
  commonDirectory: WorktreeIdentity, registry: ProjectRegistry,
  slots: [WorktreeIdentity: ProjectSlot]
) -> HostControlProjectLookup {
  guard let project = registry.project(commonDirectory),
    case .available(let model) = slots[commonDirectory]
  else {
    return .failure(
      .failure(code: .notRegistered, message: "利用可能な登録済み Project が見つかりません"))
  }
  return .available(project, model)
}

/// セッションを作ってから目的だけ弾くと、作ったセッションが残るので、作る前に検査する。
func hostControlPurposeFailure(_ purpose: String?) -> HostControlResponse? {
  guard let purpose else { return nil }
  do {
    try TmuxPanePurposeWriter.validate(purpose)
    return nil
  } catch {
    let reason =
      switch error {
      case .containsLineBreakOrControlCharacter: "改行や制御文字を含んでいます"
      case .endsWithSemicolon: "末尾が ; です"
      case .tooLong(let byteCount, let limit): "長すぎます (\(byteCount) / \(limit) バイト)"
      case .invalidPaneID(let pane): "pane ID が不正です: \(pane.rawValue)"
      case .tmux(let failure): "tmux への書き込みに失敗しました: \(failure)"
      }
    return .failure(code: .invalidRequest, message: "purpose が不正です: \(reason)")
  }
}

@MainActor
func openWorktreeWithValidatedAgentCommand(
  agentCommand: String?, open: @MainActor () async -> HostControlResponse,
  isRegistered: @MainActor () -> Bool
) async -> HostControlResponse {
  guard case .success(let command) = ProjectAgentCommand.normalized(agentCommand ?? "") else {
    return .failure(
      code: .invalidRequest,
      message: "保存された Agent 起動コマンドが不正です。Project の設定で直してください")
  }
  let response = await open()
  guard isRegistered() else {
    return .failure(code: .notRegistered, message: "処理中に Project の登録が解除されました")
  }
  if case .opened(var opened) = response {
    opened.agentCommand = command
    return .opened(opened)
  }
  return response
}

@MainActor
final class HostControlEnvironmentTask {
  var task: Task<Void, Never>?

  deinit {
    task?.cancel()
  }
}
