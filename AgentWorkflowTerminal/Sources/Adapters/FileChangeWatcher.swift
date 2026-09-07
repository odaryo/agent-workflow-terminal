import Foundation

public struct FileChangeObservationInterval: Sendable, Hashable {
  public let duration: Duration

  public static let `default` = Self(duration: .milliseconds(100))

  public init(duration: Duration) {
    precondition(duration > .zero, "duration は正でなければならない")
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

  public init(path: URL, interval: FileChangeObservationInterval = .default) {
    self.path = path
    self.interval = interval
  }

  public func events() -> AsyncStream<FileChangeEvent> {
    let initial = FileChangeSignature.read(path: path)
    return AsyncStream { continuation in
      let task = Task {
        var previous = initial
        do {
          while !Task.isCancelled {
            try await ContinuousClock().sleep(for: interval.duration)
            let current = FileChangeSignature.read(path: path)
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
  let size: UInt64
  let modificationDate: Date

  static func read(path: URL) -> Self? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
      let inode = attributes[.systemFileNumber] as? NSNumber,
      let size = attributes[.size] as? NSNumber,
      let modificationDate = attributes[.modificationDate] as? Date
    else { return nil }
    return Self(
      inode: inode.uint64Value,
      size: size.uint64Value,
      modificationDate: modificationDate)
  }
}
