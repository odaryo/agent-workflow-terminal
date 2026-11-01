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
  private let socketExists: @Sendable (String) -> Bool

  /// `socketExists` の既定は、`lstat` が成功し `S_IFSOCK` であること。
  public init(
    runner: any ProcessRunning,
    executable: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
    timeout: Duration = .seconds(3),
    socketExists: (@Sendable (String) -> Bool)? = nil
  ) {
    self.runner = runner
    self.executable = executable
    self.timeout = timeout
    self.socketExists = socketExists ?? Self.isSocket
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
        executableURL: executable, arguments: ["-w", "-U", "-a", "-c", "tmux", "-F", "pn"],
        environment: ["LC_ALL": "C"], timeout: timeout)
      if result.exitCode == 0 {
        let processIDs = LsofUnixSocketList.processIDs(listening: socketPath, in: result.stdout)
        if !processIDs.isEmpty {
          // socket が在れば tmux は既存の server に繋ぐので、2つ目の server はできない。一覧の失敗
          // から probe までの間に起きた健全な server も lsof には一致として出るため、これを
          // 取り残されたと誤らない (Issue #500 のレビューの計測)。
          return socketExists(socketPath) ? .absent : .orphaned(processIDs: processIDs)
        }
        return absenceUnlessEscaped(socketPath)
      }
      // lsof はどのエラーでも exit 1 を返すので、stderr のある exit 1 は「一致が無い」と区別できない。
      // 照会と無関係な警告 (応答しないマウントの stat 失敗など) でここに落ちないよう `-w` で警告を
      // 抑える。`-w` でも不正な引数などの本物のエラーは stderr に残る (lsof 4.91 で計測、#500)。
      if result.exitCode == 1, result.stdout.isEmpty, result.stderr.isEmpty {
        return absenceUnlessEscaped(socketPath)
      }
      return .undetermined("lsof exit \(result.exitCode): \(result.stderr)")
    } catch {
      return .undetermined("lsof: \(error)")
    }
  }

  /// symlink を辿らない `lstat` で見る (Issue #500 の決定)。
  private static func isSocket(_ path: String) -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0 else { return false }
    return status.st_mode & S_IFMT == S_IFSOCK
  }

  /// lsof (revision 4.91) の `n` 行は socket のパスをバイトのまま出すとは限らない (Issue #500 の
  /// レビューの計測、tmux 3.8)。非 ASCII は `LC_ALL=C` で `\xe6…` に、タブと `\` は locale によらず
  /// `\t` / `\\` になり、制御文字は `^A` になってリテラルの `^A` と区別できない。tmux の stderr は
  /// 生のバイトなので、こうしたパスでは server が生きていても完全一致しない。逆変換して照合しないのは、
  /// `^A` のように元のバイト列が一意に決まらない表記があるため。一致が無いことを不在と言えるのは、
  /// lsof がそのまま出すと分かっている文字だけのパスに限る。
  private func absenceUnlessEscaped(_ socketPath: String) -> TmuxOrphanedServerProbeResult {
    let mayBeEscaped = socketPath.utf8.contains { byte in
      byte < 0x20 || byte > 0x7E || byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "^")
    }
    return mayBeEscaped ? .undetermined("socket path contains characters lsof escapes") : .absent
  }
}
