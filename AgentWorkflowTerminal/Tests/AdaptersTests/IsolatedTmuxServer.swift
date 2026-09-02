import Adapters
import Darwin
import Foundation
import TerminalCore

/// 統合テスト専用の隔離 tmux server。`-L` の socket 名でのみ分離するため、socket 名は
/// 呼び出しごとに一意にする。body の成否にかかわらず server を停止し、停止を確認できたときだけ
/// socket を消す (生きている server の socket を消すと `-L` から到達できない orphan になる)。
enum IsolatedTmuxServer {
  /// server 起動時にユーザーの rc を読ませない。これが無いと `-L` で起動した新 server も
  /// `$HOME/.tmux.conf` を source し、`status-position` などレイアウトに効く設定がホストから
  /// 入り込む (実測: rc 有りで `status-position top` / `prefix C-q` が引き継がれた)。
  /// `TmuxRunner` が前置する `-u -L <socket>` の直後に置いて効くことを実測で確認している。
  private static let noConfigFile = ["-f", "/dev/null"]
  /// rc を読ませない分、split 後の pane で起動するコマンドはここで明示する。これが無いと
  /// 既定 shell が起動し、実行時間と出力がホスト環境に依存する。
  private static let defaultCommand = "sleep 300"
  /// pane 幅・高さは、左右分割と上下分割の双方が `no space for new pane` にならない値を実測で選ぶ。
  private static let windowWidth = 200
  private static let windowHeight = 50

  static func executableURL() -> URL? {
    TmuxRunner.defaultExecutableCandidates.first {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
  }

  static func withServer<T>(
    socketName: String,
    body: (TmuxRunner) async throws -> T
  ) async throws -> T {
    guard let executableURL = executableURL() else {
      throw IsolatedTmuxServerError.tmuxBinaryNotFound
    }
    let runner = try TmuxRunner(
      socketName: socketName,
      processRunner: FoundationProcessRunner(),
      executableCandidates: [executableURL]
    )
    let socketURL = socketURL(socketName: socketName)

    // new-session が成功した時点で server は存在する。以降は初期化の失敗も含め、必ず停止を通す。
    let created = try await runner.run(arguments: noConfigFile + newSessionArguments)
    let serverPID = pid_t(created.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

    let result: Result<T, any Error>
    do {
      guard let serverPID, serverPID > 0 else {
        throw IsolatedTmuxServerError.invalidServerPID(created.stdout)
      }
      _ = try await runner.run(arguments: ["set-option", "-g", "default-command", defaultCommand])
      result = .success(try await body(runner))
    } catch {
      result = .failure(error)
    }
    await stopServer(runner, serverPID: serverPID, socketURL: socketURL)
    return try result.get()
  }

  /// `#{pane_left}` / `#{pane_top}` は分割の向きを、`#{window_zoomed_flag}` は zoom 状態を、
  /// 実装ではなく tmux 側の観測値として固定するために読む。
  static func panes(_ runner: TmuxRunner) async throws -> [PaneRow] {
    let format = [
      "#{pane_id}", "#{pane_active}", "#{window_zoomed_flag}", "#{pane_left}", "#{pane_top}",
    ].joined(separator: " ")
    let output = try await runner.run(arguments: ["list-panes", "-a", "-F", format])
    return try output.stdout
      .split(separator: "\n")
      .map { try PaneRow(line: String($0)) }
  }

  static func paneIDs(_ runner: TmuxRunner) async throws -> [PaneID] {
    try await panes(runner).map(\.id)
  }

  static func activePaneID(_ runner: TmuxRunner) async throws -> PaneID? {
    try await panes(runner).first { $0.isActive }?.id
  }

  private static var newSessionArguments: [String] {
    [
      "new-session", "-d", "-s", "awt-operations",
      "-x", String(windowWidth), "-y", String(windowHeight),
      "-P", "-F", "#{pid}", defaultCommand,
    ]
  }

  /// `serverPID` が `nil` なのは `#{pid}` を読めなかったときだけで、その場合は `kill-server` の
  /// 成否だけで判断する。
  private static func stopServer(
    _ runner: TmuxRunner,
    serverPID: pid_t?,
    socketURL: URL
  ) async {
    var serverWasStopped =
      (try? await runner.run(arguments: ["kill-server"], timeout: .seconds(1))) != nil
    if !serverWasStopped, let serverPID {
      serverWasStopped = terminate(serverPID)
    }
    guard serverWasStopped else {
      // テストの成否は変えない。手で片付ける必要があることだけ伝える。
      FileHandle.standardError.write(
        Data("警告: tmux server を停止できなかったため socket を残します: \(socketURL.path)\n".utf8)
      )
      return
    }
    try? FileManager.default.removeItem(at: socketURL)
  }

  private static func socketURL(socketName: String) -> URL {
    let socketParent = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/private/tmp"
    return URL(fileURLWithPath: socketParent)
      .appending(path: "tmux-\(getuid())")
      .appending(path: socketName)
  }

  /// 戻り値は「停止を確認できたか」。`errno` は失敗した syscall の直後だけを読む (短絡に依存)。
  private static func terminate(_ serverPID: pid_t) -> Bool {
    // 0 以下は kill(2) でプロセスグループや全プロセスを指すため、syscall へ渡す前に弾く。
    guard serverPID > 0 else { return false }
    guard Darwin.kill(serverPID, SIGTERM) == 0 else { return errno == ESRCH }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(500))
    while clock.now < deadline {
      guard Darwin.kill(serverPID, 0) == 0 else { return errno == ESRCH }
      Darwin.usleep(10_000)
    }
    return Darwin.kill(serverPID, 0) != 0 && errno == ESRCH
  }
}

enum IsolatedTmuxServerError: Error, Equatable {
  case tmuxBinaryNotFound
  case invalidServerPID(String)
  case invalidPaneRow(String)
}

struct PaneRow: Sendable, Equatable {
  let id: PaneID
  let isActive: Bool
  let isZoomed: Bool
  let left: Int
  let top: Int

  init(line: String) throws {
    let fields = line.split(separator: " ")
    guard fields.count == 5,
      let left = Int(fields[3]),
      let top = Int(fields[4])
    else {
      throw IsolatedTmuxServerError.invalidPaneRow(line)
    }
    self.id = PaneID(rawValue: String(fields[0]))
    self.isActive = fields[1] == "1"
    self.isZoomed = fields[2] == "1"
    self.left = left
    self.top = top
  }
}

func uniqueSocketName(_ label: String) -> String {
  "awt-\(label)-\(ProcessInfo.processInfo.processIdentifier)-\(UInt32.random(in: 0..<1_000_000))"
}
