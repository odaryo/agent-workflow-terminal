import Foundation
import TerminalCore
import os

@testable import Adapters

/// テストから進める `ContinuousTimeSource`。TTL の主張を実時計から切り離すために使う。
/// `now` が同期プロパティなので actor にはできず、`TestTimeSource`
/// (TerminalCoreTests) と同じくロックで守る。
struct ManualTimeSource: ContinuousTimeSource {
  private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock().now)

  var now: ContinuousClock.Instant { instant.withLock { $0 } }

  func advance(by duration: Duration) {
    instant.withLock { $0 = $0.advanced(by: duration) }
  }

  func sleep(until deadline: ContinuousClock.Instant) async throws {}
}

/// 起動を種類ごとに数える `ProcessRunning`。tmux のバッチ argv を実 tmux と同じ規則で
/// 組み立て直して応答する (capture の直後にマーカー行、失敗した pane 以降は打ち切り)。
actor ObservationProcessSpy: ProcessRunning {
  enum Kind: Hashable, Sendable {
    case ps
    case captureBatch(paneCount: Int)
    case listPanes
    case other(String)

    var isCaptureBatch: Bool {
      guard case .captureBatch = self else { return false }
      return true
    }
  }

  private(set) var invocations: [[String]] = []
  private(set) var kinds: [Kind] = []
  private(set) var batchCount = 0

  /// pane ごとの画面列。バッチ n 回目は `min(n, count - 1)` 番目を返す。
  private var screens: [PaneID: [String]]
  private var missing: Set<PaneID>
  private let listPanesOutput: String
  private let processTableOutput: String
  private var listPanesFailure: ProcessRunResult?

  init(
    screens: [PaneID: [String]] = [:],
    missing: Set<PaneID> = [],
    listPanesOutput: String = "",
    processTableOutput: String = "",
    listPanesFailure: ProcessRunResult? = nil
  ) {
    self.screens = screens
    self.missing = missing
    self.listPanesOutput = listPanesOutput
    self.processTableOutput = processTableOutput
    self.listPanesFailure = listPanesFailure
  }

  func setMissing(_ panes: Set<PaneID>) { missing = panes }

  func count(of kind: Kind) -> Int { kinds.filter { $0 == kind }.count }

  var captureBatchCount: Int { kinds.filter(\.isCaptureBatch).count }

  func run(
    executableURL: URL, arguments: [String], environment: [String: String],
    timeout: Duration, outputLimit: Int
  ) async throws(ProcessRunnerError) -> ProcessRunResult {
    invocations.append(arguments)
    if executableURL.lastPathComponent == "ps" {
      kinds.append(.ps)
      return ProcessRunResult(exitCode: 0, stdout: processTableOutput, stderr: "")
    }
    if arguments.contains("capture-pane") {
      let request = Self.parseBatch(arguments)
      kinds.append(.captureBatch(paneCount: request.panes.count))
      defer { batchCount += 1 }
      return respond(to: request)
    }
    if arguments.contains("list-panes") {
      kinds.append(.listPanes)
      if let listPanesFailure { return listPanesFailure }
      return ProcessRunResult(exitCode: 0, stdout: listPanesOutput, stderr: "")
    }
    kinds.append(.other(arguments.last ?? ""))
    return ProcessRunResult(exitCode: 0, stdout: "", stderr: "")
  }

  private func respond(to request: (panes: [PaneID], nonce: String)) -> ProcessRunResult {
    var stdout = ""
    for pane in request.panes {
      guard !missing.contains(pane) else {
        return ProcessRunResult(
          exitCode: 1, stdout: stdout, stderr: "can't find pane: \(pane.rawValue)\n")
      }
      let sequence = screens[pane] ?? ["\n"]
      stdout += sequence[min(batchCount, sequence.count - 1)]
      stdout += "\(request.nonce) \(pane.rawValue)\n"
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }

  static func parseBatch(_ arguments: [String]) -> (panes: [PaneID], nonce: String) {
    var panes: [PaneID] = []
    var nonce = ""
    var index = 0
    while index < arguments.count {
      if arguments[index] == "capture-pane", index + 4 < arguments.count {
        panes.append(PaneID(rawValue: arguments[index + 4]))
        index += 5
        continue
      }
      if arguments[index] == "display-message", index + 4 < arguments.count {
        nonce = String(arguments[index + 4].split(separator: " ")[0])
        index += 5
        continue
      }
      index += 1
    }
    return (panes, nonce)
  }
}

func makeTmuxRunner(
  socketName: String, processRunner: some ProcessRunning
) throws -> TmuxRunner {
  try TmuxRunner(
    socketName: socketName, processRunner: processRunner,
    executableCandidates: [URL(fileURLWithPath: "/tmux")],
    parentEnvironment: [:], isExecutableFile: { _ in true }
  )
}

/// `TmuxListPanes.format` の14フィールドを、区切りに生 0x1F を使って組み立てた1行。
/// tmux 3.7c の非 control-mode 出力がこの形で、parser は両版を受理する。
func makeListPanesLine(session: String, paneID: String, panePID: Int32) -> String {
  [
    paneID, session, "0", "@0", "0", String(panePID), "1", "sh", "0", "", "",
    "/dev/ttys000", "/tmp", "title",
  ].joined(separator: "\u{1F}") + "\n"
}

func makePaneSnapshot(id: String, pid: Int32, title: String = "") -> PaneSnapshot {
  PaneSnapshot(
    id: PaneID(rawValue: id), processID: pid, tty: "", currentCommand: "",
    currentPath: "", title: title, termination: nil
  )
}
