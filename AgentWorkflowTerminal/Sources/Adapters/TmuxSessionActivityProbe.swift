import Foundation
import TerminalCore

public struct TmuxSessionActivityProbe: Sendable {
  private let tmuxRunner: TmuxRunner
  private let processRunner: any ProcessRunning
  private let processExecutableURL: URL

  public init(
    tmuxRunner: TmuxRunner,
    processRunner: any ProcessRunning,
    processExecutableURL: URL = URL(fileURLWithPath: "/bin/ps")
  ) {
    self.tmuxRunner = tmuxRunner
    self.processRunner = processRunner
    self.processExecutableURL = processExecutableURL
  }

  public func activity(of session: TerminalSessionKey) async -> TerminalSessionActivity {
    let name = TmuxSessionName(key: session)
    do {
      // pane_current_command は前面のプロセスグループの先頭名なので、スクリプトや sh -c を
      // shell だけと見誤る (tmux 3.8、#455 のレビュー)。
      let paneResult = try await tmuxRunner.run(
        arguments: [
          "list-panes", "-s", "-t", "=\(name.rawValue)", "-F", "#{pane_pid} #{pane_dead}",
        ])
      guard let panes = Self.parsePanes(paneResult.stdout) else { return .undetermined }
      // session を殺すかの判断に古い表を使わないため、生存観測用のキャッシュは共有しない。
      let processResult = try await processRunner.run(
        executableURL: processExecutableURL, arguments: ["-Ao", "pid=,ppid=,comm="],
        environment: ["LC_ALL": "C"], timeout: .seconds(10))
      guard processResult.exitCode == 0,
        let snapshot = Self.parseProcessTable(processResult.stdout)
      else { return .undetermined }
      return snapshot.sessionActivity(of: panes)
    } catch {
      return .undetermined
    }
  }

  private static func parsePanes(_ output: String) -> [(pid: Int32, isDead: Bool)]? {
    guard !output.isEmpty else { return nil }
    var lines = output.components(separatedBy: "\n")
    if output.last == "\n" { lines.removeLast() }
    var panes: [(pid: Int32, isDead: Bool)] = []
    var hasFailure = false
    for line in lines {
      let fields = line.split(separator: " ", omittingEmptySubsequences: false)
      guard fields.count == 2, let pid = Int32(fields[0]), pid > 0,
        fields[1] == "0" || fields[1] == "1"
      else {
        hasFailure = true
        continue
      }
      panes.append((pid: pid, isDead: fields[1] == "1"))
    }
    return hasFailure ? nil : panes
  }

  private static func parseProcessTable(_ output: String) -> ProcessTableSnapshot? {
    let lines = output.split(separator: "\n")
    guard !lines.isEmpty,
      lines.allSatisfy({ line in
        let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        return fields.count == 3 && Int32(fields[0]) != nil && Int32(fields[1]) != nil
      })
    else { return nil }
    return ProcessTableSnapshot.parse(output)
  }
}
