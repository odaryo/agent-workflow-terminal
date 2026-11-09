import Darwin
import Foundation
import TerminalCore

extension AppModel {
  func rescanNow() async {
    await hostControlRescan.request()
  }

  func openWorktreeForAgent(directory: String) async -> HostControlResponse {
    await rescanNow()
    let candidates = worktrees.map {
      (identity: $0.identity, worktreePath: $0.detected.worktreePath)
    }
    let projectRootPath = projectRoot?.worktreePath
    let paths = await Task.detached {
      (
        directory: Self.realPath(directory),
        projectRoot: projectRootPath.flatMap { Self.realPath($0) },
        worktrees: candidates.map { (identity: $0.identity, path: Self.realPath($0.worktreePath)) }
      )
    }.value
    guard !Task.isCancelled else {
      return .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした")
    }
    guard let canonicalDirectory = paths.directory else {
      return .failure(code: .notRegistered, message: "登録済みの worktree が見つかりません")
    }
    if paths.projectRoot == canonicalDirectory {
      return .failure(code: .projectRoot, message: "Project Root は指定できません")
    }
    guard
      let identity = paths.worktrees.first(where: { $0.path == canonicalDirectory })?.identity,
      let worktree = worktrees.first(where: { $0.identity == identity })
    else {
      return .failure(code: .notRegistered, message: "登録済みの worktree が見つかりません")
    }
    guard worktree.detected.isReachable else {
      return .failure(code: .unreachable, message: "worktree へ到達できません")
    }
    return await openHostControlSession(for: worktree)
  }

  private func openHostControlSession(for worktree: TaskWorktree) async -> HostControlResponse {
    guard let sessions else {
      return .failure(code: .tmuxFailed, message: "tmux を利用できません")
    }
    let names: [String]
    do {
      names = try await sessions.sessionNames()
    } catch {
      return .failure(code: .tmuxFailed, message: "tmux session の一覧を取得できません: \(error)")
    }
    guard !Task.isCancelled else {
      return .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした")
    }
    let key: TerminalSessionKey
    let created: Bool
    if let index = TmuxSessionName.indices(of: worktree.identity, in: names).first,
      let existing = TerminalSessionKey(identity: worktree.identity, index: index)
    {
      key = existing
      created = false
    } else {
      guard let first = sessionLayout.tabs(in: worktree.identity).first else {
        return .failure(code: .tmuxFailed, message: "worktree のセッションが見つかりません")
      }
      key = first
      if let failure = await createHostControlSession(
        for: key, directory: worktree.detected.worktreePath)
      {
        return failure
      }
      created = true
    }
    guard !Task.isCancelled else {
      return .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした")
    }
    guard let currentWorktree = worktrees.first(where: { $0.identity == worktree.identity }) else {
      return .failure(code: .notRegistered, message: "登録済みの worktree が見つかりません")
    }
    if currentWorktree.activation == .inactive {
      setActivation(.active, of: currentWorktree.identity)
    }
    return .opened(
      HostControlOpenedWorktree(
        session: TmuxSessionName(key: key).rawValue,
        directory: currentWorktree.detected.worktreePath, created: created, agentCommand: nil))
  }

  private func createHostControlSession(
    for key: TerminalSessionKey, directory: String
  ) async -> HostControlResponse? {
    guard let sessions else {
      return .failure(code: .tmuxFailed, message: "tmux を利用できません")
    }
    let result = await sessions.attachCommand(for: key, workingDirectory: directory)
    guard !Task.isCancelled else {
      return .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした")
    }
    switch result {
    case .success(let attachment):
      if let detail = attachment.warning {
        reportSessionWarning([warning, detail].compactMap { $0 }.joined(separator: "\n"))
      }
      return nil
    case .failure(let error):
      return .failure(code: .tmuxFailed, message: "tmux session を作成できません: \(error)")
    }
  }

  nonisolated private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

@MainActor
final class HostControlRescan {
  private let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var pending: Set<UUID> = []
  private var timer: Task<Void, Never>?
  private var stopped = false

  func request() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !stopped, !Task.isCancelled else {
          continuation.resume()
          return
        }
        waiters[id] = continuation
        pending.insert(id)
        channel.continuation.yield(())
      }
    } onCancel: {
      Task { @MainActor in self.complete([id]) }
    }
  }

  func events(interval: Duration) -> AsyncStream<Void> {
    let continuation = channel.continuation
    timer = Task {
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        continuation.yield(())
      }
    }
    return channel.stream
  }

  func beginScan() -> Set<UUID> {
    let result = pending
    pending.removeAll()
    return result
  }

  func complete(_ ids: Set<UUID>) {
    for id in ids {
      pending.remove(id)
      waiters.removeValue(forKey: id)?.resume()
    }
  }

  func stop() {
    stopped = true
    timer?.cancel()
    timer = nil
    channel.continuation.finish()
    complete(Set(waiters.keys))
  }
}
