import Adapters
import Foundation
import Testing

@Suite("§7.3 表示中ファイルの変更監視")
struct FileChangeWatcherIntegrationTests {
  @Test("上書き、追記、atomic save、削除をパスの変化として通知する", .timeLimit(.minutes(1)))
  func observesPathChanges() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-watch-\(UUID().uuidString)")
    let file = root.appending(path: "target.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("aa".utf8).write(to: file)
    let watcher = FileChangeWatcher(path: file, interval: .init(duration: .milliseconds(10)))
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

  @Test("キャンセル後は変更を通知せず stream を終了する", .timeLimit(.minutes(1)))
  func stopsOnCancellation() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/awt-watch-\(UUID().uuidString)")
    let file = root.appending(path: "target.txt")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("before".utf8).write(to: file)
    let watcher = FileChangeWatcher(path: file, interval: .init(duration: .milliseconds(10)))
    let stream = watcher.events()
    let received = EventRecorder()
    let task = Task {
      for await event in stream { await received.append(event) }
    }

    task.cancel()
    await task.value
    try Data("after".utf8).write(to: file)
    #expect(await received.values.isEmpty)
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
