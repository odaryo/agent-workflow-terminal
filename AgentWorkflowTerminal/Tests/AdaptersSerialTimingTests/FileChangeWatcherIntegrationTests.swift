import Foundation
import Testing
import os

@testable import Adapters

@Suite("§7.3 表示中ファイルの変更監視")
struct FileChangeWatcherIntegrationTests {
  @Test("上書き、追記、atomic save、削除をパスの変化として通知する", .timeLimit(.minutes(1)))
  func observesPathChanges() async throws {
    try await withWatchedFile { file, watcher in
      let stream = watcher.events()
      let received = EventRecorder()
      let task = Task {
        for await event in stream { await received.append(event) }
      }
      defer { task.cancel() }

      try Data("bb".utf8).write(to: file)
      try await waitForEventCount(1, recorder: received)
      let handle = try FileHandle(forWritingTo: file)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("c".utf8))
      try handle.close()
      try await waitForEventCount(2, recorder: received)
      try Data("dd".utf8).write(to: file, options: .atomic)
      try await waitForEventCount(3, recorder: received)
      try FileManager.default.removeItem(at: file)
      try await waitForEventCount(4, recorder: received)

      #expect(await received.values.prefix(3).allSatisfy { $0 == .modified })
      #expect(await received.values.last == .deleted)
    }
  }

  @Test("削除の後に作り直した場合も順序どおり通知する", .timeLimit(.minutes(1)))
  func keepsDeleteThenCreateOrder() async throws {
    try await withWatchedFile { file, watcher in
      let stream = watcher.events()
      let received = EventRecorder()
      let task = Task {
        for await event in stream { await received.append(event) }
      }
      defer { task.cancel() }

      try FileManager.default.removeItem(at: file)
      try await waitForEventCount(1, recorder: received)
      try Data("again".utf8).write(to: file)
      try await waitForEventCount(2, recorder: received)

      #expect(await received.values == [.deleted, .modified])
    }
  }

  /// 消費が遅れた分だけ古いイベントが溜まると、UI は溜まった数だけファイルを読み直すことになる。
  /// 保持しているのが最新1件だけであることは、遅い consumer に対してしか観測できない。
  @Test("遅い consumer には溜まった数ではなく最新のイベントだけが届く", .timeLimit(.minutes(1)))
  func keepsOnlyNewestEventForSlowConsumer() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-watch-\(UUID().uuidString)")
    let file = root.appending(path: "target.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("aa".utf8).write(to: file)
    let interval = try #require(FileChangeObservationInterval(duration: .milliseconds(5)))

    let stream = FileChangeWatcher(path: file, interval: interval).events()
    let received = EventRecorder()
    let task = Task {
      for await event in stream {
        await received.append(event)
        try? await ContinuousClock().sleep(for: .milliseconds(400))
      }
    }
    defer { task.cancel() }

    for index in 0..<20 {
      try Data(repeating: 97, count: index + 1).write(to: file)
      try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    try FileManager.default.removeItem(at: file)

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while await received.values.last != .deleted, clock.now < deadline {
      try await clock.sleep(for: .milliseconds(10))
    }
    let values = await received.values
    #expect(values.last == .deleted, "受信 \(values.count) 件: \(values)")
    #expect(values.count <= 4, "受信 \(values.count) 件: \(values)")
  }

  /// 監視対象が symlink のとき、リンク先の変更を通知しない (`FileContentReader` と同じく
  /// リンクを辿らない。§8.1)。
  @Test("symlink はリンク自身の変化だけを見る", .timeLimit(.minutes(1)))
  func doesNotFollowSymbolicLink() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.txt")
    let link = root.appending(path: "link.txt")
    try Data("aa".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let interval = try #require(FileChangeObservationInterval(duration: .milliseconds(10)))

    let stream = FileChangeWatcher(path: link, interval: interval).events()
    let received = EventRecorder()
    let task = Task { for await event in stream { await received.append(event) } }
    defer { task.cancel() }

    try Data("bbbbbbbb".utf8).write(to: target)
    try await ContinuousClock().sleep(for: .milliseconds(200))
    #expect(await received.values.isEmpty)

    try FileManager.default.removeItem(at: link)
    try await waitForEventCount(1, recorder: received)
    #expect(await received.values == [.deleted])
  }

  @Test("変更が無ければ通知しない", .timeLimit(.minutes(1)))
  func staysSilentWithoutChanges() async throws {
    try await withWatchedFile { _, watcher in
      let stream = watcher.events()
      let received = EventRecorder()
      let task = Task {
        for await event in stream { await received.append(event) }
      }
      defer { task.cancel() }

      try await ContinuousClock().sleep(for: .milliseconds(200))
      #expect(await received.values.isEmpty)
    }
  }

  @Test("キャンセル後は周期を跨いでも通知しない", .timeLimit(.minutes(1)))
  func stopsOnCancellation() async throws {
    try await withWatchedFile { file, watcher in
      let stream = watcher.events()
      let received = EventRecorder()
      let task = Task {
        for await event in stream { await received.append(event) }
      }

      task.cancel()
      await task.value
      for index in 0..<5 {
        try Data("after \(index)".utf8).write(to: file)
        try await ContinuousClock().sleep(for: .milliseconds(30))
      }
      #expect(await received.values.isEmpty)
    }
  }

  /// キャンセルで監視が本当に止まったことは、イベントが来ないことだけでは示せない
  /// (consumer が死んでいるだけでも成立する)。周期ごとの観測回数で確かめる。
  /// 経過の物差しに実時間を使わないのは、機械が混むほど同じ実時間に走る周期の数が減り、
  /// 「止まっていない」側の観測回数まで一緒に小さくなるため (プロセス全体の CPU を基準に
  /// していた頃の #319 の揺れと同じ機序)。止めない watcher を 1 本残し、その観測回数を
  /// 物差しに使えば、負荷がどうであれ「止まっていなければ同じだけ観測されたはず」の量で測れる。
  @Test("キャンセルでポーリングが解放される", .timeLimit(.minutes(1)))
  func releasesPollingOnCancellation() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-watch-\(UUID().uuidString)")
    let file = root.appending(path: "target.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("aa".utf8).write(to: file)
    let interval = try #require(FileChangeObservationInterval(duration: .milliseconds(1)))

    let cancelledPolls = PollCounter()
    let witnessPolls = PollCounter()
    let cancelledStream = FileChangeWatcher(
      path: file, interval: interval, onPoll: { cancelledPolls.increment() }
    ).events()
    let witnessStream = FileChangeWatcher(
      path: file, interval: interval, onPoll: { witnessPolls.increment() }
    ).events()
    let cancelledTask = Task { for await _ in cancelledStream {} }
    let witnessTask = Task { for await _ in witnessStream {} }
    defer { witnessTask.cancel() }

    try await waitForPollCount(20, counter: cancelledPolls)
    try await waitForPollCount(20, counter: witnessPolls)
    cancelledTask.cancel()
    await cancelledTask.value

    // キャンセルが producer へ伝わるまでの猶予も、実時間ではなく物差し側の周期数で取る。
    try await waitForPollCount(witnessPolls.count + 20, counter: witnessPolls)
    let stopped = cancelledPolls.count
    try await waitForPollCount(witnessPolls.count + 50, counter: witnessPolls)

    // 入れ違いで始まっていた 1 周期は数えうる。止まっていなければ物差しと同じ ~50 回増える。
    let extra = cancelledPolls.count - stopped
    #expect(extra <= 1, "キャンセル後に \(extra) 回ポーリングした")
  }

  @Test("正でない周期を拒否する", arguments: [Duration.zero, .milliseconds(-1)])
  func rejectsNonPositiveInterval(_ duration: Duration) {
    #expect(FileChangeObservationInterval(duration: duration) == nil)
  }

  private func withWatchedFile(
    _ body: (URL, FileChangeWatcher) async throws -> Void
  ) async throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-watch-\(UUID().uuidString)")
    let file = root.appending(path: "target.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("aa".utf8).write(to: file)
    let interval = try #require(FileChangeObservationInterval(duration: .milliseconds(10)))
    try await body(file, FileChangeWatcher(path: file, interval: interval))
  }

  /// 期限は判定の物差しではなく、ポーリングが一切進まないまま吊るのを避けるための保険。
  /// 1ms 周期に対して桁違いに緩いので、負荷で先に切れることはない。
  private func waitForPollCount(_ count: Int, counter: PollCounter) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while counter.count < count {
      guard clock.now < deadline else {
        Issue.record("期限までに \(count) 回のポーリングが観測できなかった (\(counter.count) 回)")
        return
      }
      try await clock.sleep(for: .milliseconds(1))
    }
  }

  private func waitForEventCount(_ count: Int, recorder: EventRecorder) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await recorder.values.count < count {
      guard clock.now < deadline else {
        Issue.record("期限までに \(count) 件のイベントが届かなかった")
        return
      }
      try await clock.sleep(for: .milliseconds(5))
    }
  }
}

private actor EventRecorder {
  private(set) var values: [FileChangeEvent] = []
  func append(_ event: FileChangeEvent) { values.append(event) }
}

/// `onPoll` は監視 Task から同期に呼ばれるため actor へ hop できない (docs/coding-guidelines.md §1.2)。
private final class PollCounter: Sendable {
  private let state = OSAllocatedUnfairLock(initialState: 0)

  var count: Int { state.withLock { $0 } }

  func increment() { state.withLock { $0 += 1 } }
}
