import Foundation
import TerminalCore

public enum TmuxSessionOperationError: Error, Sendable, Equatable {
  /// tmux の target 構文で特別扱いされる文字を含む名前。tmux へ渡す前に弾いた場合だけこれになる。
  case invalidSessionName(TmuxSessionName)
  /// tmux 3.4 実測: exit 1 と stderr `can't find session: <name>\n`。
  /// 「対象が既に無い」を成功へ丸めないのは `TmuxPaneOperations.paneNotFound` と同じ理由による。
  case sessionNotFound(TmuxSessionName)
  /// tmux 3.4 実測: exit 1 と stderr `duplicate session: <name>\n`。
  /// 設計書 §3.3 の「既存 session があれば Resume する」を上位が判断できるよう、成功にも
  /// 一般エラーにも丸めずに返す。
  case sessionAlreadyExists(TmuxSessionName)
  /// tmux 3.4 実測: exit 1 と stderr `no server running on <socket path>\n`。
  case serverNotRunning
  /// tmux は存在しないディレクトリを渡されても exit 0 で session を作り、pane の cwd は
  /// `$HOME` へ落ちる (tmux 3.4 実測)。作った session が黙って別のディレクトリで動くのを
  /// 防ぐため、`create` はこれをエラーにする。
  case workingDirectoryNotFound(String)
  /// 上記へ分類しなかった失敗。終了コード・stdout・stderr を加工せずに保持する。
  /// tmux の非ゼロ終了を「正常状態」と「エラー」へ一般に分類するのは Issue #62 の担当。
  case tmux(TmuxRunnerError)
}

/// 複数クライアントが同時 attach したときの window サイズ (設計書 §4.2)。
/// tmux の `manual` を含めないのは、`-x` / `-y` の指定とセットでしか意味を持たず、
/// この型が提供しない操作だからである。
public enum TmuxWindowSize: String, Sendable, Hashable, CaseIterable {
  case smallest
  case largest
  case latest
}

/// worktree のライフサイクル (設計書 §3.3 / §3.4) に必要な session 操作だけを提供する。
/// rename・attach・swap・group 化は §4.1 の「完全 GUI は作らない」に従ってここへ足さない。
///
/// 対象の指定には必ず `=` を前置する。tmux 3.4 の実測では `has-session -t awt-probe` が
/// `awt-probe-deadbeef` にヒットして exit 0 になる (候補が1つに絞れるときだけ前方一致する)。
/// ユーザー自身の session と名前空間を共有する (§4.1) 以上、前方一致は他人の session を
/// 消しかねない。`=` は大文字小文字も区別する (実測)。
public struct TmuxSessionOperations: Sendable {
  /// 設計書 §4.4 の製品既定。pane 単位でおよそ25MB (174桁 × 10000行) を見込む。
  public static let defaultHistoryLimit = 10_000
  /// 設計書 §4.2 の製品既定。全クライアントが全内容を見られるのはこれだけ。
  public static let defaultWindowSize = TmuxWindowSize.smallest

  private let runner: TmuxRunner
  private let directoryExists: @Sendable (String) -> Bool

  public init(runner: TmuxRunner) {
    self.init(
      runner: runner,
      directoryExists: { path in
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
      }
    )
  }

  init(runner: TmuxRunner, directoryExists: @escaping @Sendable (String) -> Bool) {
    self.runner = runner
    self.directoryExists = directoryExists
  }

  /// - Returns: server が動いていない場合も `false`。§3.3 で見たいのは「Resume できる session が
  ///   あるか」だけで、server の生死は同じ答えに畳めるため。分類できない失敗は投げる。
  public func exists(session: TmuxSessionName) async throws(TmuxSessionOperationError) -> Bool {
    do {
      _ = try await run(["has-session", "-t", Self.exactTarget(session)], session: session)
      return true
    } catch {
      switch error {
      case .sessionNotFound, .serverNotRunning: return false
      default: throw error
      }
    }
  }

  /// 設計書 §4.4 の `history-limit` と §4.2 の `window-size` が、**最初の pane と実際に残る
  /// window に効いた状態**の session を作る。
  ///
  /// tmux 3.4 では pane の履歴容量が pane 生成時に確定するため、`new-session` のあとに
  /// `set-option` しても最初の pane は既定値 (`2000`) のまま残る。そこで新しい window を
  /// 作り直してから最初の window を捨てる。代替として `respawn-window -k` も実測したが、
  /// pane を作り直さないため履歴容量は `2000` のままだった (`%3 hist=2000`)。
  ///
  /// `window-size` は window option であり、`set-option -t <session>` はその時点の現在 window に
  /// しか効かない (実測)。そのため設定は最初の window を捨てた**あと**、残った window に対して
  /// 行う。順序を入れ替えると、捨てる window に設定して消える。
  ///
  /// - Note: 1回の tmux 実行にまとめるのは、`new-session` が `duplicate session` で失敗したとき
  ///   後続を実行させないため。実測では既存 session の window も option も変化しなかった。
  /// - Note: 連鎖の中では target に `=` を付けていない。`set-option` は `=` 付きを
  ///   `no such session: =<name>` で拒否する (実測) 一方、直前の `new-session` の成功が完全一致の
  ///   session の存在を保証しているため、前方一致に落ちる余地が無い。
  /// - Note: 残る window の index は 1 になる (捨てるのが index 0 のため)。表示上の見え方だけの
  ///   問題なので、番号を詰め直すコマンドは足していない。
  public func create(
    session: TmuxSessionName,
    workingDirectory: String,
    historyLimit: Int = Self.defaultHistoryLimit,
    windowSize: TmuxWindowSize = Self.defaultWindowSize
  ) async throws(TmuxSessionOperationError) {
    guard directoryExists(workingDirectory) else {
      throw .workingDirectoryNotFound(workingDirectory)
    }

    let name = session.rawValue
    _ = try await run(
      [
        "new-session", "-d", "-s", name, "-c", workingDirectory,
        ";", "set-option", "-t", name, "history-limit", String(historyLimit),
        ";", "new-window", "-d", "-t", name, "-c", workingDirectory,
        ";", "kill-window", "-t", "\(name):^",
        ";", "set-option", "-w", "-t", "\(name):", "window-size", windowSize.rawValue,
      ],
      session: session
    )
  }

  /// - Note: 「もう無かった」を成功へ丸めず `sessionNotFound` で返す。server ごと落ちていた
  ///   場合も同様に `serverNotRunning` を返す。どちらを成功と見なすかは Close の選択肢
  ///   (§3.4) ごとに違うため、ここでは決めない。
  public func kill(session: TmuxSessionName) async throws(TmuxSessionOperationError) {
    _ = try await run(["kill-session", "-t", Self.exactTarget(session)], session: session)
  }

  /// server にある session 名をそのまま返す。
  ///
  /// **`awt-` prefix でのフィルタをここで行わない。** ユーザーは同じ prefix の session を自分で
  /// 作れるので、prefix はアプリの管理下であることの証明にならない。どれが管理下かは、安定 ID
  /// から導出した名前 (`TmuxSessionName`) と突き合わせて上位が判断する。
  ///
  /// - Returns: server が動いていなければ空配列。session が1つも無いことと同じ答えになるため。
  public func list() async throws(TmuxSessionOperationError) -> [String] {
    do {
      let result = try await run(["list-sessions", "-F", "#{session_name}"], session: nil)
      return result.stdout.split(separator: "\n").map(String.init)
    } catch {
      switch error {
      case .serverNotRunning: return []
      default: throw error
      }
    }
  }

  private func run(
    _ arguments: [String],
    session: TmuxSessionName?
  ) async throws(TmuxSessionOperationError) -> ProcessRunResult {
    if let session, !Self.isWellFormed(session) {
      throw .invalidSessionName(session)
    }
    do {
      return try await runner.run(arguments: arguments)
    } catch {
      throw Self.mapFailure(error, session: session)
    }
  }

  private static func mapFailure(
    _ error: TmuxRunnerError,
    session: TmuxSessionName?
  ) -> TmuxSessionOperationError {
    guard case .commandFailed(let exitCode, _, let stderr) = error, exitCode == 1 else {
      return .tmux(error)
    }
    // socket path が続くため前方一致で見る。
    if stderr.hasPrefix("no server running on ") {
      return .serverNotRunning
    }
    guard let session else {
      return .tmux(error)
    }
    // `=` は tmux 側のメッセージには現れない (実測)。
    switch stderr {
    case "can't find session: \(session.rawValue)\n": return .sessionNotFound(session)
    case "duplicate session: \(session.rawValue)\n": return .sessionAlreadyExists(session)
    default: return .tmux(error)
    }
  }

  private static func exactTarget(_ session: TmuxSessionName) -> String {
    "=\(session.rawValue)"
  }

  /// `TmuxSessionName` は導出でしか作れないため常にこの形になるが、値は `<name>:^` のような
  /// target 構文へ埋め込まれ、tmux は `:` `.` を区切りとして、`=` `$` `@` `%` を種別の印として
  /// 解釈する。tmux へ渡す前に、導出規則 (設計書 §3.5) が生む文字だけであることを確かめる。
  private static func isWellFormed(_ session: TmuxSessionName) -> Bool {
    guard !session.rawValue.isEmpty else { return false }
    return session.rawValue.allSatisfy { character in
      guard character.isASCII else { return false }
      return character.isLetter || character.isNumber || character == "_" || character == "-"
    }
  }
}
