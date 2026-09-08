import Foundation
import TerminalCore

public enum TmuxAgentSignalSourceError: Error, Sendable, Equatable {
  case paneNotFound(PaneID)
  case paneListMalformed([TmuxListPanesParseFailure])
  case tmux(TmuxRunnerError)
  case capture(TmuxCapturePaneError)
}

public enum TmuxCapturePaneError: Error, Sendable, Equatable {
  case invalidPaneID(PaneID)
  case tmux(TmuxRunnerError)
}

public struct TmuxCapturePane: Sendable {
  private let runner: TmuxRunner
  public init(runner: TmuxRunner) { self.runner = runner }
  /// 返り値は SGR / OSC を含む生の画面。文字属性 (dim) が Claude Code の入力欄で
  /// プレースホルダと入力済みテキストを分ける唯一の手掛かりであり、plain 側は
  /// これを剥がして作る (Issue #217)。`-p` と併せて2回起動しないのは §7.5 の観測コスト制約。
  public func captureWithEscapeSequences(
    _ pane: PaneID
  ) async throws(TmuxCapturePaneError) -> String {
    guard Self.isWellFormed(pane) else {
      throw .invalidPaneID(pane)
    }
    do {
      return try await runner.run(
        arguments: ["capture-pane", "-e", "-p", "-t", pane.rawValue]
      ).stdout
    } catch {
      throw .tmux(error)
    }
  }

  static func isWellFormed(_ pane: PaneID) -> Bool {
    pane.rawValue.first == "%" && !pane.rawValue.dropFirst().isEmpty
      && pane.rawValue.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
  }
}

/// pane の軽量信号は2回の tmux 起動、process 生存確認は別周期で取得する
/// (Spikes/gate3/README.md §7.5、§10-2、§11)。
public actor TmuxAgentSignalSource: AgentSignalSource {
  private let tmuxRunner: TmuxRunner
  private let capturePane: TmuxCapturePane
  private let processRunner: any ProcessRunning
  private let processExecutableURL: URL
  private var screenChangeTracker = AgentScreenChangeTracker()

  public init(
    tmuxRunner: TmuxRunner, processRunner: any ProcessRunning,
    processExecutableURL: URL = URL(fileURLWithPath: "/bin/ps")
  ) {
    self.tmuxRunner = tmuxRunner
    self.capturePane = TmuxCapturePane(runner: tmuxRunner)
    self.processRunner = processRunner
    self.processExecutableURL = processExecutableURL
  }

  public func signals(
    for pane: PaneSnapshot, minimumChangedLines: Int
  ) async throws -> AgentSignals {
    guard TmuxCapturePane.isWellFormed(pane.id) else {
      throw TmuxAgentSignalSourceError.capture(.invalidPaneID(pane.id))
    }
    let displayed: ProcessRunResult
    do {
      displayed = try await tmuxRunner.run(
        arguments: [
          "display-message", "-p", "-t", pane.id.rawValue,
          TmuxListPanes.agentPaneStatusFormat,
        ]
      )
    } catch {
      screenChangeTracker.forget(paneID: pane.id)
      throw TmuxAgentSignalSourceError.tmux(error)
    }
    let status: TmuxAgentPaneStatus
    do { status = try TmuxListPanes.parseAgentPaneStatus(output: displayed.stdout) } catch {
      if case .invalidPaneID(let rawValue) = error, rawValue.isEmpty {
        screenChangeTracker.forget(paneID: pane.id)
        throw TmuxAgentSignalSourceError.paneNotFound(pane.id)
      }
      throw TmuxAgentSignalSourceError.paneListMalformed([
        TmuxListPanesParseFailure(lineNumber: 1, line: displayed.stdout, error: error)
      ])
    }
    guard status.paneID == pane.id else {
      screenChangeTracker.forget(paneID: pane.id)
      throw TmuxAgentSignalSourceError.paneNotFound(pane.id)
    }
    let styledScreen: String?
    do {
      styledScreen = try await capturePane.captureWithEscapeSequences(pane.id)
    } catch {
      screenChangeTracker.forget(paneID: pane.id)
      styledScreen = nil
    }
    // 画面変化の計測は plain 側で行う。属性だけが変わったフレーム (spinner の色替えなど) を
    // 出力とみなすと `secondsSinceScreenChange` が 0 に張り付く。
    let screen = styledScreen.map { StyledScreenText(capturedWithEscapeSequences: $0).plainText }
    // await 後に採ることで、actor 再入時も古い時刻で changedAt を上書きしない。
    let capturedAt = ContinuousClock().now
    let observedAt = Date()
    let secondsSinceScreenChange = screen.flatMap {
      screenChangeTracker.observe(
        screen: $0, paneID: pane.id, at: capturedAt, minimumChangedLines: minimumChangedLines)
    }
    return AgentSignals(
      paneTitle: status.title, screenText: screen, styledScreenText: styledScreen,
      secondsSinceScreenChange: secondsSinceScreenChange,
      observedAt: observedAt
    )
  }

  public func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    guard !pane.isDead else {
      screenChangeTracker.forget(paneID: pane.id)
      return .absent
    }
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: processExecutableURL, arguments: ["-Ao", "pid=,ppid=,comm="],
        environment: ["LC_ALL": "C"], timeout: .seconds(10)
      )
    } catch { return .undetermined }
    guard result.exitCode == 0 else { return .undetermined }
    let names = Self.processTreeNames(of: pane.processID, rows: Self.parseProcesses(result.stdout))
    let liveness =
      names.isDisjoint(with: matchingProcessNames)
      ? AgentLiveness.absent : .alive
    if liveness == .absent { screenChangeTracker.forget(paneID: pane.id) }
    return liveness
  }

  public func forget(_ pane: PaneSnapshot) {
    screenChangeTracker.forget(paneID: pane.id)
  }

  private struct ProcessRow: Sendable {
    let pid: Int32
    let parentPID: Int32
    let name: String
  }

  private static func parseProcesses(_ output: String) -> [ProcessRow] {
    output.split(separator: "\n").compactMap { line in
      let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
      guard fields.count == 3, let pid = Int32(fields[0]), let parentPID = Int32(fields[1]) else {
        return nil
      }
      let command = String(fields[2])
      return ProcessRow(
        pid: pid, parentPID: parentPID,
        name: command.split(separator: "/").last.map(String.init) ?? command
      )
    }
  }

  private static func processTreeNames(of root: Int32, rows: [ProcessRow]) -> Set<String> {
    let children = Dictionary(grouping: rows, by: \.parentPID)
    // dead pane は上で除外済みなので、直接 exec された Agent を拾うため pane_pid 自身から辿る。
    var pending = rows.filter { $0.pid == root }
    var names: Set<String> = []
    while let row = pending.popLast() {
      names.insert(row.name)
      pending.append(contentsOf: children[row.pid] ?? [])
    }
    return names
  }
}
