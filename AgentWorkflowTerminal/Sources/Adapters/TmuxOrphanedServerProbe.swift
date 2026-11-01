import Foundation

public enum TmuxOrphanedServerProbeResult: Sendable, Equatable {
  case absent
  case orphaned(processIDs: [Int32])
  case undetermined(String)
}

/// macOS 27 の `/usr/sbin/lsof` と tmux 3.8 で計測: 一致する process が無ければ
/// exit 1 で出力も無い。非ゼロ終了を一律に失敗へ写すと、不在を確定できなくなる (Issue #500)。
public struct TmuxOrphanedServerProbe: Sendable {
  private let runner: any ProcessRunning
  private let executable: URL
  private let timeout: Duration

  public init(
    runner: any ProcessRunning,
    executable: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
    timeout: Duration = .seconds(3)
  ) {
    self.runner = runner
    self.executable = executable
    self.timeout = timeout
  }

  #if os(macOS)
  public init(
    executable: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
    timeout: Duration = .seconds(3)
  ) {
    self.init(runner: FoundationProcessRunner(), executable: executable, timeout: timeout)
  }
  #endif

  public func probe(socketPath: String) async -> TmuxOrphanedServerProbeResult {
    do {
      let result = try await runner.run(
        executableURL: executable, arguments: ["-U", "-a", "-c", "tmux", "-F", "pn"],
        environment: ["LC_ALL": "C"], timeout: timeout)
      if result.exitCode == 0 {
        let processIDs = LsofUnixSocketList.processIDs(listening: socketPath, in: result.stdout)
        return processIDs.isEmpty ? .absent : .orphaned(processIDs: processIDs)
      }
      if result.exitCode == 1, result.stdout.isEmpty { return .absent }
      return .undetermined("lsof exit \(result.exitCode): \(result.stderr)")
    } catch {
      return .undetermined("lsof: \(error)")
    }
  }
}
