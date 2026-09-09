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
///   global option は `runner.serverArguments` をそのまま前置する — ここを自前で組むと
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

  init(runner: TmuxRunner, tmuxExecutable: URL) {
    self.operations = TmuxSessionOperations(runner: runner)
    self.runner = runner
    self.tmuxExecutable = tmuxExecutable
  }

  /// - Returns: 成功時は surface へ渡す attach の argv。
  func attachCommand(
    for identity: WorktreeIdentity,
    workingDirectory: String
  ) async -> Result<[String], TmuxSessionOperationError> {
    let session = TmuxSessionName(identity: identity)
    do {
      try await operations.create(session: session, workingDirectory: workingDirectory)
    } catch .sessionAlreadyExists {
      // 設計書 §3.3 の Resume。`exists` で先に分けないのは、`exists` と `create` の間に
      // 他のクライアントが同じ名前を作る窓があり、そこで返るこの値も Resume だからである。
    } catch .serverNotRunning {
      return await attachCommandBootstrappingServer(
        session: session, workingDirectory: workingDirectory)
    } catch {
      return .failure(error)
    }
    return .success(attachCommand(for: session))
  }

  /// `-A` を持たない `attach-session` にする。session が消えていた場合に、§4.2 / §4.4 の
  /// 保証が掛かっていない session を surface が黙って作り直す経路を残さないため。
  /// `=` は前方一致でユーザー自身の session を掴まないための完全一致指定
  /// (`TmuxSessionOperations` の doc 参照)。
  private func attachCommand(for session: TmuxSessionName) -> [String] {
    [tmuxExecutable.path, "-u", "attach-session", "-t", "=\(session.rawValue)"]
  }

  /// server が動いていないときだけ通る経路。`create` は server を起こさないと決めているので
  /// (`TmuxSessionOperations.create` の doc)、起こす側をここに置く。
  ///
  /// - Important: **`tmux start-server` では代用できない。** tmux 3.4 は session を1つも持たない
  ///   server を即座に終了させるため、`start-server` は rc=0 を返しても server を残さない
  ///   (Issue #235 で実測)。session を1つ作ることが、server を残す唯一の手段である。
  private func attachCommandBootstrappingServer(
    session: TmuxSessionName,
    workingDirectory: String
  ) async -> Result<[String], TmuxSessionOperationError> {
    await startBootstrapSession()
    let result: Result<[String], TmuxSessionOperationError>
    do {
      try await operations.create(session: session, workingDirectory: workingDirectory)
      result = .success(attachCommand(for: session))
    } catch .sessionAlreadyExists {
      result = .success(attachCommand(for: session))
    } catch {
      result = .failure(error)
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
      arguments: runner.serverArguments
        + ["new-session", "-d", "-s", Self.bootstrapSessionName, "-c", "/"],
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
    case .serverNotRunning:
      "tmux server が動いていないため、session を用意できません。"
    default:
      "tmux session を用意できません: \(self)"
    }
  }
}
