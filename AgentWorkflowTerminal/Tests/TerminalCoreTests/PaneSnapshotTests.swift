import Foundation
import TerminalCore
import Testing

@Suite("PaneSnapshot の終了状態")
struct PaneSnapshotTests {
  @Test(
    "終了理由の有無から dead を導出する",
    arguments: [
      nil,
      ProcessTermination.exited(status: 0),
      ProcessTermination.signaled("term"),
      ProcessTermination.unknown,
    ]
  )
  func derivesDeadState(termination: ProcessTermination?) {
    let snapshot = PaneSnapshot(
      id: PaneID(rawValue: "%0"),
      processID: 123,
      tty: "/dev/ttys000",
      currentCommand: "zsh",
      currentPath: "/tmp",
      title: "title",
      termination: termination
    )

    #expect(snapshot.isDead == (termination != nil))
  }
}

@Suite("§12.4.2 PaneSnapshot の list-panes 時刻")
struct PaneSnapshotListedAtTests {
  @Test("s1: listedAt だけが違う snapshot は等しく、hash も等しい")
  func listedAtIsExcludedFromEquality() throws {
    let listedAt = ContinuousClock().now
    let earlier = snapshot(listedAt: listedAt)
    let later = snapshot(listedAt: listedAt.advanced(by: .seconds(2)))
    try #require(earlier.listedAt != later.listedAt)

    #expect(earlier == later)
    #expect(earlier.hashValue == later.hashValue)
  }

  @Test("s2: エンコードしてデコードすると listedAt は nil になり、ほかの値は保つ")
  func listedAtIsNotEncoded() throws {
    let original = snapshot(listedAt: ContinuousClock().now)

    let decoded = try JSONDecoder().decode(
      PaneSnapshot.self, from: try JSONEncoder().encode(original))

    #expect(decoded.listedAt == nil)
    #expect(decoded == original)
    #expect(decoded.id == original.id)
    #expect(decoded.processID == original.processID)
    #expect(decoded.tty == original.tty)
    #expect(decoded.currentCommand == original.currentCommand)
    #expect(decoded.currentPath == original.currentPath)
    #expect(decoded.title == original.title)
    #expect(decoded.termination == original.termination)
  }

  private func snapshot(listedAt: ContinuousClock.Instant) -> PaneSnapshot {
    PaneSnapshot(
      id: PaneID(rawValue: "%3"), processID: 321, tty: "/dev/ttys003", currentCommand: "claude",
      currentPath: "/repo", title: "title", termination: .exited(status: 1), listedAt: listedAt)
  }
}
