import Adapters
import Foundation
import TerminalCore

/// タブが端末を出す前に、その worktree の tmux session を用意する経路。
///
/// **surface へ `new-session` を渡さない**ための型である。§4.4 の `history-limit` と §4.2 の
/// `window-size`、`-c` の format escape は `TmuxSessionOperations.create` だけが保証しており、
/// surface 側で同じ argv を組み直すと同じ判定が2箇所へ分かれる (Issue #235 はそれで
/// 3つとも本番に効いていなかった)。
///
/// - Important: server を起こす経路 (`startBootstrapSession`) だけは `TmuxRunner` を通さず argv を
///   自分で組む (限定環境を server へ焼き付けないため)。接続先が `create` と食い違わないよう、
///   global option は `runner.serverScopedArguments` を通す — ここを自前で組むと
///   `-L` を持つ runner で起こす server と `create` が見る server が割れる。
struct TmuxSessionProvisioner: Sendable {
  /// server を起こすためだけに作って必ず消す session の名前。
  ///
  /// `TmuxSessionName` は必ず `awt-<slug>-<16進8桁>` で終わるので、最後の `-` の後ろが
  /// 8桁の16進でないこの名前は、どの worktree からも導出されない。`create` の doc が言う
  /// 前方一致事故を避けるため、kill は `-t '=<名前>'` の完全一致で撃つ。
  private static let bootstrapSessionName = "awt-bootstrap-server-do-not-use"

  private let operations: TmuxSessionOperations
  private let runner: TmuxRunner
  private let tmuxExecutable: URL
  private let orphanedServerProbe: TmuxOrphanedServerProbe

  init(
    runner: TmuxRunner, tmuxExecutable: URL,
    orphanedServerProbe: TmuxOrphanedServerProbe = TmuxOrphanedServerProbe()
  ) {
    self.operations = TmuxSessionOperations(runner: runner)
    self.runner = runner
    self.tmuxExecutable = tmuxExecutable
    self.orphanedServerProbe = orphanedServerProbe
  }

  /// 空配列は「session が無い」ことの確認である。取り残された server が居る場合は `[]` にせず投げる。
  /// 呼び出し側が空の一覧でタブを刈り込まないため (Issue #500)。
  func sessionNames() async throws(TmuxSessionProvisionerError) -> [String] {
    do {
      return try await operations.list()
    } catch .serverNotRunning {
      return []
    } catch .serverSocketMissing(let socketPath) {
      switch await orphanedServerProbe.probe(socketPath: socketPath) {
      case .absent: return []
      case let result: throw .orphanedServer(socketPath: socketPath, result)
      }
    } catch {
      throw .operation(error)
    }
  }

  func exists(_ key: TerminalSessionKey) async throws(TmuxSessionOperationError) -> Bool {
    try await operations.exists(session: TmuxSessionName(key: key))
  }

  func terminate(_ key: TerminalSessionKey) async throws(TmuxSessionProvisionerError) {
    do {
      try await operations.kill(session: TmuxSessionName(key: key))
    } catch .sessionNotFound, .serverNotRunning {
      return
    } catch .serverSocketMissing(let socketPath) {
      switch await orphanedServerProbe.probe(socketPath: socketPath) {
      case .absent: return
      case let result: throw .orphanedServer(socketPath: socketPath, result)
      }
    } catch {
      throw .operation(error)
    }
  }

  /// - Returns: 成功時は surface へ渡す attach の argv。
  func attachCommand(
    for key: TerminalSessionKey,
    workingDirectory: String
  ) async -> Result<[String], TmuxSessionProvisionerError> {
    let session = TmuxSessionName(key: key)
    do {
      try await operations.create(session: session, workingDirectory: workingDirectory)
    } catch .sessionAlreadyExists {
      // 設計書 §3.3 の Resume。`exists` で先に分けないのは、`exists` と `create` の間に
      // 他のクライアントが同じ名前を作る窓があり、そこで返るこの値も Resume だからである。
      // 旧版やアプリ外で作られた session は設定が無いので、Resume のたびに入れ直す (#491)。
      do {
        try await operations.ensureDetachOnDestroy(session: session)
      } catch {
        // session 消滅は attach 側で失敗が表示される。それ以外の設定失敗でもタブを開けなく
        // する方が害が大きいため、ここでは attach を止めない。
        NSLog(
          "[app] session \(session.rawValue) の detach-on-destroy 設定に失敗: \(error)")
      }
    } catch .serverNotRunning {
      return await attachCommandBootstrappingServer(
        session: session, workingDirectory: workingDirectory)
    } catch .serverSocketMissing(let socketPath) {
      // 生存中の server の socket だけが消えた場合に起こすと、同じパスに2つ目の server ができ、
      // 古い server の session と Agent が辿れなくなる (Issue #500)。
      switch await orphanedServerProbe.probe(socketPath: socketPath) {
      case .absent:
        return await attachCommandBootstrappingServer(
          session: session, workingDirectory: workingDirectory)
      case let result:
        return .failure(.orphanedServer(socketPath: socketPath, result))
      }
    } catch {
      return .failure(.operation(error))
    }
    return .success(attachCommand(for: session))
  }

  /// `-A` を持たない `attach-session` にする。session が消えていた場合に、§4.2 / §4.4 の
  /// 保証が掛かっていない session を surface が黙って作り直す経路を残さないため。
  /// `=` は前方一致でユーザー自身の session を掴まないための完全一致指定
  /// (`TmuxSessionOperations` の doc 参照)。
  ///
  /// global option を `runner` から取るのは、この argv を実行するのは surface であって
  /// `runner` ではないためである。自前で `-u` と書くと、`-L` を持つ runner では
  /// `create` が作った server と attach 先が割れる。
  private func attachCommand(for session: TmuxSessionName) -> [String] {
    [tmuxExecutable.path]
      + runner.serverScopedArguments(["attach-session", "-t", "=\(session.rawValue)"])
  }

  /// `create` は server を起こさないと決めているので (`TmuxSessionOperations.create` の doc)、
  /// 起こす側をここに置く。socket 欠落はこの経路へ通す前に、取り残された server が居ないことを
  /// 確認する (Issue #500)。
  ///
  /// - Important: **`tmux start-server` では代用できない。** tmux 3.4 は session を1つも持たない
  ///   server を即座に終了させるため、`start-server` は rc=0 を返しても server を残さない
  ///   (Issue #235 で実測)。session を1つ作ることが、server を残す唯一の手段である。
  private func attachCommandBootstrappingServer(
    session: TmuxSessionName,
    workingDirectory: String
  ) async -> Result<[String], TmuxSessionProvisionerError> {
    await startBootstrapSession()
    let result: Result<[String], TmuxSessionProvisionerError>
    do {
      try await operations.create(session: session, workingDirectory: workingDirectory)
      result = .success(attachCommand(for: session))
    } catch .sessionAlreadyExists {
      result = .success(attachCommand(for: session))
    } catch {
      result = .failure(.operation(error))
    }
    // 成否にかかわらず消す。本来の session ができていれば server は残り、できていなければ
    // server ごと落ちて起動前の状態へ戻る。
    _ = try? await runner.run(
      arguments: ["kill-session", "-t", "=\(Self.bootstrapSessionName)"])
    return result
  }

  /// - Important: **`TmuxRunner` を通さない。** server を起こした側の環境がその server の
  ///   global environment になり、同じ server 上のユーザー自身の pane まで継承する
  ///   (`TmuxSessionOperations.create` の doc の表: `LC_ALL` は server 由来で pane へ届く)。
  ///   `TmuxRunner` が渡すのは `LC_ALL=C` + `HOME` / `PATH` / `TMUX_TMPDIR` だけの限定環境なので、
  ///   ここはアプリの環境を渡す。どの環境で server を起こすかの本設計は Issue #61。
  /// - Important: **ただし `TMUX` と `TMUX_PANE` は落とす。** tmux 3.4 実測: `$TMUX` は
  ///   `TMUX_TMPDIR` より優先して socket を決める。落とさないと、tmux の中から起動された
  ///   アプリでは bootstrap が `$TMUX` の server に session を作り、`create` は
  ///   `TMUX_TMPDIR` 側の server を見て、後始末の `kill-session` も (`TmuxRunner` 経由なので)
  ///   そちら側へ飛ぶ。結果として bootstrap session がユーザーの生きた server に残る
  ///   (Issue #235 のラウンド2で実アプリで再現した)。`TMUX_TMPDIR` は逆に残さねばならない
  ///   — `TmuxRunner` が継承しており、落とすと socket の親が食い違う。
  /// - Note: `-c /` に固定する。worktree のパスをこの経路へ渡さないことで、§4.4 の
  ///   `history-limit` と `-c` の format escape がここに関与しなくなる — それらの保証は
  ///   `create` だけが持つ。
  /// - Note: 失敗を無視するのは、前回の異常終了で同名の session が残っている場合に
  ///   `duplicate session` で失敗するのが正常だからである。その session でも server は動いており、
  ///   後段の `create` の結果がこの経路の答えになる。
  private func startBootstrapSession() async {
    var environment = ProcessInfo.processInfo.environment
    environment["TMUX"] = nil
    environment["TMUX_PANE"] = nil
    _ = try? await FoundationProcessRunner().run(
      executableURL: tmuxExecutable,
      arguments: runner.serverScopedArguments(
        ["new-session", "-d", "-s", Self.bootstrapSessionName, "-c", "/"]),
      environment: environment,
      timeout: TmuxRunner.defaultTimeout
    )
  }
}

extension TmuxSessionOperationError {
  /// 画面に出す理由。原因ごとにユーザーの次の行動が違うので、1つの文言へ丸めない。
  var terminalTabDescription: String {
    switch self {
    case .workingDirectoryUnusable(let path):
      "worktree のディレクトリへ入れないため、session を用意できません: \(path)"
    case .invalidWorkingDirectory(let path):
      "worktree のパスを tmux へ渡せないため、session を用意できません: \(path)"
    case .leftoverSession(let session, let cause, let cleanupFailure):
      """
      設定に失敗した session が残っています。手で `tmux kill-session -t =\(session.rawValue)` \
      してください: 原因 \(cause) / 後始末の失敗 \(cleanupFailure)
      """
    case .serverNotRunning, .serverSocketMissing:
      "tmux server が動いていないため、session を用意できません。"
    default:
      "tmux session を用意できません: \(self)"
    }
  }
}

/// - Important: `.orphanedServer` に `.absent` は載せない。
enum TmuxSessionProvisionerError: Error, Equatable, CustomStringConvertible {
  case operation(TmuxSessionOperationError)
  case orphanedServer(socketPath: String, TmuxOrphanedServerProbeResult)

  var terminalTabDescription: String {
    switch self {
    case .operation(let error): error.terminalTabDescription
    case .orphanedServer(let socketPath, let result):
      result.orphanedServerExplanation(socketPath: socketPath)
    }
  }

  var description: String {
    switch self {
    case .operation(let error): "\(error)"
    case .orphanedServer(let socketPath, let result):
      result.orphanedServerExplanation(socketPath: socketPath)
    }
  }
}

extension TmuxOrphanedServerProbeResult {
  /// アプリ自身は `kill` を送らない。手順を示すだけに留める (Issue #500)。
  func orphanedServerExplanation(socketPath: String) -> String {
    switch self {
    case .orphaned(let processIDs):
      let pids = processIDs.map(String.init).joined(separator: ", ")
      let kill = processIDs.map { "kill -USR1 \($0)" }.joined(separator: " / ")
      return
        "tmux の socket (\(socketPath)) が消えていますが、tmux server (pid \(pids)) はまだ動いています。"
        + "ターミナルで `\(kill)` を実行すると socket が作り直され、再試行で繋がります。"
    case .undetermined(let reason):
      return
        "tmux の socket (\(socketPath)) が見つかりません。tmux server が動いているかを確かめられなかったため、"
        + "新しい server は起動していません。(\(reason))"
    case .absent:
      return "tmux の socket (\(socketPath)) が見つかりません。"
    }
  }
}
