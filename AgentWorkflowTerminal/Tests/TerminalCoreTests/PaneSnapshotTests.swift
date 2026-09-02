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
