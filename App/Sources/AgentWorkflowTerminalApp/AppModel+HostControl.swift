import Darwin
import Foundation
import TerminalCore

extension AppModel {
  func rescanNow() async {
    await hostControlRescan.request()
  }

  func openWorktreeForAgent(directory: String) async -> HostControlResponse {
    await rescanNow()
    guard let canonicalDirectory = Self.realPath(directory) else {
      return .failure(code: .notRegistered, message: "登録済みの worktree が見つかりません")
    }
    if let projectRoot, Self.realPath(projectRoot.worktreePath) == canonicalDirectory {
      return .failure(code: .projectRoot, message: "Project Root は指定できません")
    }
    guard
      let worktree = worktrees.first(where: {
        Self.realPath($0.detected.worktreePath) == canonicalDirectory
      })
    else {
      return .failure(code: .notRegistered, message: "登録済みの worktree が見つかりません")
    }
    guard worktree.detected.isReachable else {
      return .failure(code: .unreachable, message: "worktree へ到達できません")
    }
    guard let sessions else {
      return .failure(code: .tmuxFailed, message: "tmux を利用できません")
    }
    let names: [String]
    do {
      names = try await sessions.sessionNames()
    } catch {
      return .failure(code: .tmuxFailed, message: "tmux session の一覧を取得できません: \(error)")
    }
    let key: TerminalSessionKey
    let created: Bool
    if let index = TmuxSessionName.indices(of: worktree.identity, in: names).first,
      let existing = TerminalSessionKey(identity: worktree.identity, index: index)
    {
      key = existing
      created = false
    } else {
      key = .primary(worktree.identity)
      if case .failure(let error) = await sessions.attachCommand(
        for: key, workingDirectory: worktree.detected.worktreePath)
      {
        return .failure(code: .tmuxFailed, message: "tmux session を作成できません: \(error)")
      }
      created = true
    }
    if worktree.activation == .inactive {
      setActivation(.active, of: worktree.identity)
    }
    return .opened(
      HostControlOpenedWorktree(
        session: TmuxSessionName(key: key).rawValue,
        directory: worktree.detected.worktreePath, created: created, agentCommand: nil))
  }

  private static func realPath(_ path: String) -> String? {
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
