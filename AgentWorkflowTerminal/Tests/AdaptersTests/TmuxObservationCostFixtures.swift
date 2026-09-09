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
  /// pane ごとの title 列。画面と同じ規則で進む。
  private var titles: [PaneID: [String]]
  /// `capture-pane` の時点で消えている pane。列はここで exit 1 で止まる。
  private var missing: Set<PaneID>
  /// capture は成功したが marker の時点で消えている pane。tmux 3.4 の `display-message` は
  /// 存在しない pane でも exit 0 で空の `#{pane_id}` を返し、**列は止まらない** (実測)。
  private var vanishingAfterCapture: Set<PaneID>
  /// このいずれかを含むグループは `outputLimitExceeded` にする。
  private var oversized: Set<PaneID>
  private let listPanesOutput: String
  private let processTableOutput: String
  private var listPanesFailure: ProcessRunResult?

  init(
    screens: [PaneID: [String]] = [:],
    titles: [PaneID: [String]] = [:],
    missing: Set<PaneID> = [],
    vanishingAfterCapture: Set<PaneID> = [],
    oversized: Set<PaneID> = [],
    listPanesOutput: String = "",
    processTableOutput: String = "",
    listPanesFailure: ProcessRunResult? = nil
  ) {
    self.screens = screens
    self.titles = titles
    self.missing = missing
    self.vanishingAfterCapture = vanishingAfterCapture
    self.oversized = oversized
    self.listPanesOutput = listPanesOutput
    self.processTableOutput = processTableOutput
    self.listPanesFailure = listPanesFailure
  }

  func setMissing(_ panes: Set<PaneID>) { missing = panes }

  func setVanishingAfterCapture(_ panes: Set<PaneID>) { vanishingAfterCapture = panes }

  func setOversized(_ panes: Set<PaneID>) { oversized = panes }

  func setTitles(_ value: [PaneID: [String]]) { titles = value }

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
      guard oversized.isDisjoint(with: request.panes) else {
        throw .outputLimitExceeded(limit: outputLimit)
      }
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

  private func respond(to request: BatchRequest) -> ProcessRunResult {
    var stdout = ""
    for pane in request.panes {
      guard !missing.contains(pane) else {
        return ProcessRunResult(
          exitCode: 1, stdout: stdout, stderr: "can't find pane: \(pane.rawValue)\n")
      }
      let sequence = screens[pane] ?? ["\n"]
      stdout += sequence[min(batchCount, sequence.count - 1)]
      // 消えた pane では `#{pane_id}` も `#{pane_title}` も空になる (tmux 3.4 実測)。
      let vanished = vanishingAfterCapture.contains(pane)
      let titleSequence = titles[pane] ?? [""]
      stdout += "\(request.nonce) "
      stdout += Self.render(
        format: request.format,
        paneID: vanished ? "" : pane.rawValue,
        title: vanished ? "" : titleSequence[min(batchCount, titleSequence.count - 1)])
      stdout += "\n"
    }
    return ProcessRunResult(exitCode: 0, stdout: stdout, stderr: "")
  }

  /// tmux 3.4 の format 展開のうち、marker が使う分だけを再現する。区切りの Unit Separator は
  /// 非 control-mode 出力で `\037` になり、`s/\\/\\\\/` は値の backslash を二重化し、
  /// 出力段は `$` の前に `\` を足す (いずれも実測)。
  static func render(format: String, paneID: String, title: String) -> String {
    let escapedTitle =
      title
      .replacingOccurrences(of: #"\"#, with: #"\\"#)
      .replacingOccurrences(of: "$", with: #"\$"#)
    return
      format
      .replacingOccurrences(of: "#{pane_id}", with: paneID)
      .replacingOccurrences(of: #"#{s/\\/\\\\/:pane_title}"#, with: escapedTitle)
      .replacingOccurrences(of: "\u{1F}", with: #"\037"#)
  }

  struct BatchRequest {
    let panes: [PaneID]
    let nonce: String
    /// marker template から nonce と空白を除いた残り。実装が何を要求したかをそのまま映す。
    let format: String
  }

  static func parseBatch(_ arguments: [String]) -> BatchRequest {
    var panes: [PaneID] = []
    var nonce = ""
    var format = ""
    var index = 0
    while index < arguments.count {
      if arguments[index] == "capture-pane", index + 4 < arguments.count {
        panes.append(PaneID(rawValue: arguments[index + 4]))
        index += 5
        continue
      }
      if arguments[index] == "display-message", index + 4 < arguments.count {
        let template = arguments[index + 4]
        let parts = template.split(separator: " ", maxSplits: 1)
        nonce = String(parts[0])
        format = parts.count > 1 ? String(parts[1]) : ""
        index += 5
        continue
      }
      index += 1
    }
    return BatchRequest(panes: panes, nonce: nonce, format: format)
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
