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
        return await self.enqueueHostControl(request)
      }
      hostControlServer = server
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
      return await handleHostControlWithDeadline(request)
    }
    pendingHostControl = task
    return await task.value
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
    case .openWorktree(let directory):
      guard directory.hasPrefix("/"), !directory.utf8.contains(0) else {
        return .failure(code: .invalidRequest, message: "directory は空でない絶対パスを指定してください")
      }
      let project: RegisteredProject
      do {
        project = try await resolver.resolve(directory: URL(fileURLWithPath: directory))
      } catch {
        return .failure(code: .notRegistered, message: "登録済みの Project を解決できません")
      }
      guard !Task.isCancelled else {
        return .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした")
      }
      guard registry.project(project.commonDirectory) != nil,
        case .available(let model) = slots[project.commonDirectory]
      else {
        return .failure(code: .notRegistered, message: "利用可能な登録済み Project が見つかりません")
      }
      let response = await model.openWorktreeForAgent(directory: directory)
      if case .opened(var opened) = response {
        opened.agentCommand = registry.project(project.commonDirectory)?.agentCommand
        return .opened(opened)
      }
      return response
    }
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

@MainActor
final class HostControlEnvironmentTask {
  var task: Task<Void, Never>?

  deinit {
    task?.cancel()
  }
}
