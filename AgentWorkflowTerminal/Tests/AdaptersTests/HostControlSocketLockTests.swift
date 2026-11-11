import Darwin
import Foundation
import Testing

@testable import Adapters

enum LockInterference: CaseIterable, Sendable {
  case replaced
  case removed
}

@Suite("hostctl の lock の再試行 §21.4")
struct HostControlSocketLockTests {
  @Test("lockの実ファイルの差し替えと削除をinodeで判別する")
  func detectsReplacedLock() throws {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    let descriptor = try SocketIO.lock(path)
    defer { Darwin.close(descriptor) }
    #expect(try SocketIO.isCurrentLock(descriptor, path: path))
    try FileManager.default.removeItem(atPath: path + ".lock")
    #expect(try !SocketIO.isCurrentLock(descriptor, path: path))
    let replacement = try SocketIO.lock(path)
    defer { Darwin.close(replacement) }
    #expect(try !SocketIO.isCurrentLock(descriptor, path: path))
    #expect(try SocketIO.isCurrentLock(replacement, path: path))
  }

  @Test(
    "最初のopenの後にlockを差し替えられると開き直して現在のlockを返す",
    arguments: LockInterference.allCases)
  func reopensChangedLock(_ interference: LockInterference) throws {
    let path = uniquePath()
    let lockPath = path + ".lock"
    let replacementPath = path + ".replacement"
    defer {
      try? FileManager.default.removeItem(atPath: lockPath)
      try? FileManager.default.removeItem(atPath: replacementPath)
    }
    var calls = 0
    let descriptor = try SocketIO.lock(path) { _ in
      calls += 1
      guard calls == 1 else { return }
      switch interference {
      case .replaced:
        #expect(FileManager.default.createFile(atPath: replacementPath, contents: nil))
        #expect(Darwin.rename(replacementPath, lockPath) == 0)
      case .removed:
        #expect(Darwin.unlink(lockPath) == 0)
      }
    }
    defer { Darwin.close(descriptor) }
    #expect(calls == 2)
    var opened = stat()
    try #require(Darwin.fstat(descriptor, &opened) == 0)
    var current = stat()
    try #require(Darwin.lstat(lockPath, &current) == 0)
    #expect(opened.st_ino == current.st_ino)
    #expect(opened.st_dev == current.st_dev)
  }

  @Test("開くたびにlockを削除されると再試行を使い切ってaddressInUseを投げる")
  func givesUpWhenLockKeepsDisappearing() {
    let path = uniquePath()
    defer { try? FileManager.default.removeItem(atPath: path + ".lock") }
    var calls = 0
    var returned: Int32?
    defer { if let returned { Darwin.close(returned) } }
    do throws(HostControlSocketError) {
      returned = try SocketIO.lock(path) { _ in
        calls += 1
        #expect(Darwin.unlink(path + ".lock") == 0)
      }
      Issue.record("lockを削除され続けても取得できた")
    } catch {
      #expect(error == .addressInUse(path))
    }
    #expect(calls == 11)
  }

  private func uniquePath() -> String {
    "/private/tmp/awt-hc-\(UUID().uuidString).sock"
  }
}
