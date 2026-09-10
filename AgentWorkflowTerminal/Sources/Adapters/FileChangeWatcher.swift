import Darwin
import Foundation

public struct FileChangeObservationInterval: Sendable, Hashable {
  public let duration: Duration

  public static let `default` = Self(validated: .milliseconds(100))

  public init?(duration: Duration) {
    guard duration > .zero else { return nil }
    self.duration = duration
  }

  private init(validated duration: Duration) {
    self.duration = duration
  }
}

public enum FileChangeEvent: Sendable, Hashable {
  case modified
  case deleted
}

public struct FileChangeWatcher: Sendable {
  public let path: URL
  public let interval: FileChangeObservationInterval
  /// 観測専用の seam で、製品経路では常に nil (#319)。監視 Task の上で周期ごとに同期に呼ばれるので、
  /// 重い処理やブロックする処理を渡すとポーリング周期そのものが伸び、測っている量が変わる。
  let onPoll: (@Sendable () -> Void)?

  public init(path: URL, interval: FileChangeObservationInterval = .default) {
    self.init(path: path, interval: interval, onPoll: nil)
  }

  init(
    path: URL, interval: FileChangeObservationInterval, onPoll: (@Sendable () -> Void)?
  ) {
    self.path = path
    self.interval = interval
    self.onPoll = onPoll
  }

  /// 比較の起点は監視 Task の開始前に読む。Task 開始後に読むと、その間の変更を取りこぼす。
  public func events() -> AsyncStream<FileChangeEvent> {
    let initial = FileChangeSignature.read(path: path)
    // イベントは2値しか持たないので溜まった古いものは冗長でしかなく、consumer が遅れた分だけ
    // ファイルを読み直させることになる。既定の unbounded ではなく最新1件だけを保持する。
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        var previous = initial
        do {
          while !Task.isCancelled {
            try await ContinuousClock().sleep(for: interval.duration)
            let current = FileChangeSignature.read(path: path)
            onPoll?()
            guard current != previous else { continue }
            continuation.yield(current == nil ? .deleted : .modified)
            previous = current
          }
        } catch {
          continuation.finish()
          return
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private struct FileChangeSignature: Equatable, Sendable {
  let inode: UInt64
  let size: Int64
  let modificationSeconds: Int
  let modificationNanoseconds: Int

  /// `FileManager.attributesOfItem` は同じ情報を得るのに 4 倍の CPU を使う (計測: 7.99 µs/call に
  /// 対し `stat(2)` は 1.99 µs/call)。ポーリング周期ごとに呼ぶため差が常時の消費に効く。
  /// symlink を辿らないのは `FileContentReader` と同じ理由 (§8.1)。
  static func read(path: URL) -> Self? {
    var info = stat()
    guard lstat(path.path, &info) == 0 else { return nil }
    return Self(
      inode: info.st_ino,
      size: info.st_size,
      modificationSeconds: info.st_mtimespec.tv_sec,
      modificationNanoseconds: info.st_mtimespec.tv_nsec)
  }
}
