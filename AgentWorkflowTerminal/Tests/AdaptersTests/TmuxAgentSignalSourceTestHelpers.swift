import Foundation

@testable import Adapters

func makeSource(
  spy: some ProcessRunning, clock: ManualTimeSource
) throws -> TmuxAgentSignalSource {
  TmuxAgentSignalSource(
    processTable: ProcessTableSnapshotCache(
      processRunner: spy, executableURL: URL(fileURLWithPath: "/ps"),
      timeToLive: ProcessTableSnapshotCache.defaultTimeToLive, timeSource: clock),
    screenBatcher: TmuxPaneScreenBatcher(
      runner: try makeTmuxRunner(socketName: "signals-test", processRunner: spy),
      timeToLive: TmuxPaneScreenBatcher.defaultTimeToLive, timeSource: clock)
  )
}
