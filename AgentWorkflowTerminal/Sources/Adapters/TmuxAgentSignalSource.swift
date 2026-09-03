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
    guard pane.rawValue.first == "%", !pane.rawValue.dropFirst().isEmpty,
      pane.rawValue.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
    else {
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
}

public actor TmuxAgentSignalSource: AgentSignalSource {
  private let tmuxRunner: TmuxRunner
  private let capturePane: TmuxCapturePane
  private let processRunner: any ProcessRunning
  private let processExecutableURL: URL

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
    let observedAt = Date()
    let listed: ProcessRunResult
    do {
      listed = try await tmuxRunner.run(
        arguments: ["list-panes", "-a", "-F", TmuxListPanes.format]
      )
    } catch { throw TmuxAgentSignalSourceError.tmux(error) }
    let parsed = TmuxListPanes.parse(output: listed.stdout)
    guard parsed.failures.isEmpty else {
      throw TmuxAgentSignalSourceError.paneListMalformed(parsed.failures)
    }
    guard let current = parsed.panes.first(where: { $0.paneID == pane.id }) else {
      throw TmuxAgentSignalSourceError.paneNotFound(pane.id)
    }
    let mode: ProcessRunResult
    let activity: ProcessRunResult
    do {
      mode = try await tmuxRunner.run(
        arguments: ["display-message", "-p", "-t", pane.id.rawValue, "#{pane_in_mode}"]
      )
      activity = try await tmuxRunner.run(
        arguments: ["display-message", "-p", "-t", pane.id.rawValue, "#{window_activity}"]
      )
    } catch { throw TmuxAgentSignalSourceError.tmux(error) }
    let screen: String
    do { screen = try await capturePane.capture(pane.id) } catch {
      throw TmuxAgentSignalSourceError.capture(error)
    }
    return AgentSignals(
      paneTitle: current.title, screenText: screen,
      secondsSinceOutput: TimeInterval(
        activity.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      .map { max(0, observedAt.timeIntervalSince1970 - $0) },
      isPaneInMode: mode.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1",
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
    let names = Self.descendantNames(of: pane.processID, rows: Self.parseProcesses(result.stdout))
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

  private static func descendantNames(of root: Int32, rows: [ProcessRow]) -> Set<String> {
    let children = Dictionary(grouping: rows, by: \.parentPID)
    var pending = children[root] ?? []
    var names: Set<String> = []
    while let row = pending.popLast() {
      names.insert(row.name)
      pending.append(contentsOf: children[row.pid] ?? [])
    }
    return names
  }
}
