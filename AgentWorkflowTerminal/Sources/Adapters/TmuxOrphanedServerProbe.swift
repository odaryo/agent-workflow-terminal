import Darwin
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

  /// `socketExists` は生きている socket が在るかを返す。既定は symlink を辿らず、
  /// socket ファイルであり接続できることを要求する。古いファイルだけでは生存を示せないため。
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
          // 生きた socket が在れば tmux は既存の server に繋ぐので、2つ目の server はできない。一覧の失敗
          // から probe までの間に起きた健全な server も lsof には一致として出るため、これを
          // 取り残されたと誤らない (Issue #500 のレビューの計測)。
          if socketExists(socketPath) { return .absent }
          if Self.hasAmbiguousLsofRepresentation(socketPath) {
            return .undetermined("socket path contains ambiguous lsof representations")
          }
          return .orphaned(processIDs: processIDs)
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

  /// 取り残された server の socket は unlink 済みなので、パスへの接続に応えるのは
  /// そのパスで生きている server だけ。lstat だけでは、別の server が残した古い socket を
  /// 生存と誤る (Issue #512 D3)。接続後はデータを送らず、すぐ閉じる。
  private static func isSocket(_ path: String) -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else { return false }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
  }

  /// macOS 27 の `/usr/sbin/lsof`、tmux 3.8、LC_ALL=C で計測 (Issue #500・#512、2026-11-02)。
  /// 非 ASCII は `\xe6…`、タブは `\t`、`\` は `\\`、制御文字は `^` + (バイト + 0x40)、
  /// ESC は `^[`、DEL は `\x7f` になる。リテラルの `^` はそのまま出るため、不一致から
  /// 不在と言える印字可能 ASCII に含める (D1)。tmux の stderr は生のバイトなので、
  /// 変換される文字を含むパスでは server が生きていても完全一致しない。
  private func absenceUnlessEscaped(_ socketPath: String) -> TmuxOrphanedServerProbeResult {
    let mayBeEscaped = socketPath.utf8.contains { byte in
      byte < 0x20 || byte > 0x7E || byte == UInt8(ascii: "\\")
    }
    return mayBeEscaped ? .undetermined("socket path contains characters lsof escapes") : .absent
  }

  /// `^A` や `\t` は元のバイト列が一意に決まらず、完全一致でも別の server の行かもしれない。
  /// 逆変換せず、生きた socket が無い場合の orphaned 判定を留保する (Issue #512 D2)。
  private static func hasAmbiguousLsofRepresentation(_ path: String) -> Bool {
    let bytes = path.utf8
    return bytes.contains(UInt8(ascii: "\\"))
      || zip(bytes, bytes.dropFirst()).contains { previous, current in
        previous == UInt8(ascii: "^") && (0x40...0x5F).contains(current)
      }
  }
}
