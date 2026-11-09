import Adapters
import Foundation
import TerminalCore
import Testing

@testable import AgentWorkflowTerminalApp

@MainActor
@Suite("hostctl の競合制御 (Issue #763)")
struct HostControlConcurrencyTests {
  @Test("stop は状態を保持し、スキャン待ちを解放する")
  func stopReleasesWaiters() async throws {
    let rescan = HostControlRescan()
    #expect(!rescan.isStopped)
    var iterator = rescan.events(interval: .seconds(60)).makeAsyncIterator()
    let request = Task { await rescan.request() }
    _ = await iterator.next()
    let waiters = rescan.beginScan()
    #expect(waiters.count == 1)

    rescan.stop()
    await request.value
    #expect(rescan.isStopped)
    await rescan.request()
    rescan.complete(waiters)
    rescan.scheduleNextScan()
    #expect(await iterator.next() == nil)
  }

  @Test("rescan の待機中に Project を解除すると open は登録解除を返す")
  func stoppedProjectRejectsOpen() async throws {
    let identity = try #require(WorktreeIdentity(rawValue: "/repo/.git"))
    let model = AppModel(
      project: RegisteredProject(commonDirectory: identity, directory: "/repo"),
      dependencies: AppDependencies(
        launchProject: .none, tmuxExecutable: nil, tmuxError: nil,
        paneStates: nil, tmuxRunner: nil, paneSource: nil, signalSource: nil,
        sessionActivityProbe: nil, applicationSupportDirectory: nil, applicationSupportWarning: nil),
      notifier: nil)
    defer { model.stop() }
    var iterator = model.hostControlRescan.events(interval: .seconds(60)).makeAsyncIterator()
    let open = Task { await model.openWorktreeForAgent(directory: "/repo/task") }
    _ = await iterator.next()
    model.stop()
    #expect(
      await open.value
        == .failure(code: .notRegistered, message: "Project の登録が解除されました"))
  }

  @Test("長いスキャン中に周期 tick が溜まらず、完了後に再設定する")
  func rearmsTimerAfterScan() async throws {
    let rescan = HostControlRescan()
    defer { rescan.stop() }
    var count = 0
    let consumer = Task {
      for await _ in rescan.events(interval: .milliseconds(20)) {
        _ = rescan.beginScan()
        count += 1
      }
    }
    defer { consumer.cancel() }
    try await waitUntil { count == 1 }
    try await Task.sleep(for: .milliseconds(80))
    #expect(count == 1)

    rescan.finishScan([])
    #expect(count == 1)
    try await waitUntil { count == 2 }
    try await Task.sleep(for: .milliseconds(80))
    #expect(count == 2)
    rescan.stop()
    rescan.scheduleNextScan()
    try await Task.sleep(for: .milliseconds(40))
    #expect(count == 2)
  }

  @Test("スキャン中の要求は周期の待ちを挟まず次のスキャンで完了する")
  func requestDuringScan() async throws {
    let rescan = HostControlRescan()
    defer { rescan.stop() }
    var iterator = rescan.events(interval: .seconds(60)).makeAsyncIterator()
    let first = Task { await rescan.request() }
    _ = await iterator.next()
    let firstWaiters = rescan.beginScan()
    var secondFinished = false
    let second = Task {
      await rescan.request()
      secondFinished = true
    }
    await Task.yield()
    rescan.finishScan(firstWaiters)
    await first.value
    #expect(!secondFinished)
    _ = await iterator.next()
    rescan.finishScan(rescan.beginScan())
    await second.value
    #expect(secondFinished)
  }

  @Test("同時の open は先行処理の完了後に次の処理を始める")
  func serializesOpenRequests() async throws {
    let queue = HostControlOpenQueue()
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    var order: [String] = []
    let first = Task {
      await queue.run {
        order.append("first started")
        for await _ in gate.stream { break }
        order.append("first finished")
        return .failure(code: .projectRoot, message: "first")
      }
    }
    try await waitUntil { order.count == 1 }
    let second = Task {
      await queue.run {
        order.append("second started")
        return .failure(code: .notRegistered, message: "second")
      }
    }
    for _ in 0..<100 { await Task.yield() }
    #expect(order == ["first started"])
    gate.continuation.yield(())
    #expect(await first.value == .failure(code: .projectRoot, message: "first"))
    #expect(await second.value == .failure(code: .notRegistered, message: "second"))
    #expect(order == ["first started", "first finished", "second started"])
  }

  @Test("待機中にキャンセルされた open は処理を始めず後続を妨げない")
  func cancelsQueuedRequest() async throws {
    let queue = HostControlOpenQueue()
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    var started = false
    let first = Task {
      await queue.run {
        started = true
        for await _ in gate.stream { break }
        return .failure(code: .projectRoot, message: "first")
      }
    }
    try await waitUntil { started }
    var cancelledStarted = false
    let second = Task {
      await queue.run {
        cancelledStarted = true
        return .failure(code: .projectRoot, message: "second")
      }
    }
    for _ in 0..<100 { await Task.yield() }
    second.cancel()
    gate.continuation.yield(())
    _ = await first.value
    #expect(
      await second.value
        == .failure(code: .tmuxFailed, message: "処理が時間内に終わりませんでした"))
    #expect(!cancelledStarted)
    let third = await queue.run { .failure(code: .notRegistered, message: "third") }
    #expect(third == .failure(code: .notRegistered, message: "third"))
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
  }
}
