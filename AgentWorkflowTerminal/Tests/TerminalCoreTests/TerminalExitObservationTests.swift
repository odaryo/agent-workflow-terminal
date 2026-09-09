import TerminalCore
import Testing

@Suite("プロセスの終わった端末を覆う世代の判定 (Issue #234)")
struct TerminalExitObservationTests {

  @Test("何も観測していなければ、どの世代も覆わない")
  func nothingObserved() {
    let observation = TerminalExitObservation()
    #expect(!observation.isExited(generation: 0))
    #expect(!observation.isExited(generation: 1))
  }

  @Test(".exited を観測した世代だけを覆う")
  func coversOnlyObservedGeneration() {
    var observation = TerminalExitObservation()
    observation.observe(.exited, generation: 3)
    #expect(observation.isExited(generation: 3))
    #expect(!observation.isExited(generation: 2))
    #expect(!observation.isExited(generation: 4))
  }

  @Test(".exited 以外では覆わない")
  func ignoresOtherStates() {
    for state in [
      TerminalRendererState.notStarted, .awaitingSurface, .running, .stopped,
    ] {
      var observation = TerminalExitObservation()
      observation.observe(state, generation: 0)
      #expect(!observation.isExited(generation: 0))
    }
  }

  /// `.stopped` を含めるのは、`.exited` の次に実際に届きうるのがそれだからである
  /// (覆いを出したまま別のタブへ移り、その端末が破棄される経路)。
  @Test(
    "同じ世代が .exited から戻れば覆いを下ろす",
    arguments: [TerminalRendererState.stopped, .running, .awaitingSurface]
  )
  func lowersOnSameGeneration(state: TerminalRendererState) {
    var observation = TerminalExitObservation()
    observation.observe(.exited, generation: 1)
    observation.observe(state, generation: 1)
    #expect(!observation.isExited(generation: 1))
  }

  /// 覆う世代は**後から観測した方**になる。先に観測した世代が勝つ実装だと、作り直した端末が
  /// `.exited` しても覆われない。古い世代の `.stopped` は view が解放されると届かないことが
  /// あるので (`GhosttySurfaceView.notifyStateChange` の `[weak self]`)、古い世代を覆ったまま
  /// 新しい世代が `.exited` する順序は現実に起こりうる。
  @Test("新しい世代の .exited は、古い世代の観測を上書きする")
  func newerExitReplacesOlder() {
    var observation = TerminalExitObservation()
    observation.observe(.exited, generation: 1)
    observation.observe(.exited, generation: 2)
    #expect(observation.isExited(generation: 2))
    #expect(!observation.isExited(generation: 1))
  }

  @Test("古い世代の後片付けが遅れて届いても、今覆っている世代の覆いは外れない")
  func staleStateDoesNotLowerNewerGeneration() {
    var observation = TerminalExitObservation()
    observation.observe(.exited, generation: 2)
    observation.observe(.stopped, generation: 1)
    #expect(observation.isExited(generation: 2))
  }

  @Test("古い世代の .exited が遅れて届いても、新しい世代は覆わない")
  func staleExitDoesNotCoverNewerGeneration() {
    var observation = TerminalExitObservation()
    observation.observe(.exited, generation: 1)
    #expect(!observation.isExited(generation: 2))
  }
}
