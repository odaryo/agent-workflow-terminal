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
  public func capture(_ pane: PaneID) async throws(TmuxCapturePaneError) -> String {
    guard Self.isWellFormed(pane) else {
      throw .invalidPaneID(pane)
    }
    do {
      return try await runner.run(
        arguments: ["capture-pane", "-p", "-t", pane.rawValue]
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

  public func signals(for pane: PaneSnapshot) async throws -> AgentSignals {
    guard TmuxCapturePane.isWellFormed(pane.id) else {
      throw TmuxAgentSignalSourceError.capture(.invalidPaneID(pane.id))
    }
    let observedAt = Date()
    let displayed: ProcessRunResult
    do {
      displayed = try await tmuxRunner.run(
        arguments: [
          "display-message", "-p", "-t", pane.id.rawValue,
          TmuxListPanes.agentPaneStatusFormat,
        ]
      )
    } catch { throw TmuxAgentSignalSourceError.tmux(error) }
    let status: TmuxAgentPaneStatus
    do { status = try TmuxListPanes.parseAgentPaneStatus(output: displayed.stdout) } catch {
      if case .invalidPaneID(let rawValue) = error, rawValue.isEmpty {
        throw TmuxAgentSignalSourceError.paneNotFound(pane.id)
      }
      throw TmuxAgentSignalSourceError.paneListMalformed([
        TmuxListPanesParseFailure(lineNumber: 1, line: displayed.stdout, error: error)
      ])
    }
    guard status.paneID == pane.id else {
      throw TmuxAgentSignalSourceError.paneNotFound(pane.id)
    }
    let screen: String
    do { screen = try await capturePane.capture(pane.id) } catch {
      throw TmuxAgentSignalSourceError.capture(error)
    }
    let secondsSinceScreenChange = screenChangeTracker.observe(
      screen: screen, paneID: pane.id, at: observedAt
    )
    return AgentSignals(
      paneTitle: status.title, screenText: screen,
      secondsSinceScreenChange: secondsSinceScreenChange,
      observedAt: observedAt
    )
  }

  public func liveness(
    for pane: PaneSnapshot, matchingProcessNames: Set<String>
  ) async -> AgentLiveness {
    guard !pane.isDead else { return .absent }
    let result: ProcessRunResult
    do {
      result = try await processRunner.run(
        executableURL: processExecutableURL, arguments: ["-Ao", "pid=,ppid=,comm="],
        environment: ["LC_ALL": "C"], timeout: .seconds(10)
      )
    } catch { return .undetermined }
    guard result.exitCode == 0 else { return .undetermined }
    let names = Self.processTreeNames(of: pane.processID, rows: Self.parseProcesses(result.stdout))
    return names.isDisjoint(with: matchingProcessNames) ? .absent : .alive
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
