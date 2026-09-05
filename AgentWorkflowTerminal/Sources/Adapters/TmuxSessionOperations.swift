import Foundation
import TerminalCore

public enum TmuxSessionOperationError: Error, Sendable, Equatable {
  /// tmux 3.4 実測: exit 1 と stderr `can't find session: <name>\n`。
  /// 「対象が既に無い」を成功へ丸めないのは `TmuxPaneOperations.paneNotFound` と同じ理由による。
  case sessionNotFound(TmuxSessionName)
  /// tmux 3.4 実測: exit 1 と stderr `duplicate session: <name>\n`。
  /// 設計書 §3.3 の「既存 session があれば Resume する」を上位が判断できるよう、成功にも
  /// 一般エラーにも丸めずに返す。
  case sessionAlreadyExists(TmuxSessionName)
  /// server が動いていない。tmux 3.4 はこれを socket ファイルの状態で2通りに書き分ける
  /// (`TmuxSessionOperations.isServerAbsent` に実測した文字列がある)。
  case serverNotRunning
  /// tmux は存在しないディレクトリを渡されても exit 0 で session を作り、pane の cwd は
  /// `$HOME` へ落ちる (tmux 3.4 実測)。通常ファイルを渡した場合も同じ。
  case workingDirectoryNotFound(String)
  /// tmux の引数解釈で値が変わってしまう作業ディレクトリ (`TmuxSessionOperations.isSafeArgument`)。
  case invalidWorkingDirectory(String)
  /// tmux が受け付けない `history-limit` (`TmuxSessionOperations.historyLimitRange`)。
  case invalidHistoryLimit(Int)
  /// `new-session -P -F '#{session_id}'` が `$N` 以外を返した。原文を捨てずに載せる。
  case unexpectedSessionIDOutput(String)
  /// session を作った後の設定で失敗し、**その後始末にも失敗した**。この worktree には
  /// §4.2 / §4.4 を満たさない session が残っており、`exists` は Resume 可能と答える。
  /// 呼び出し側が手を打てるよう、原因と後始末の失敗を両方載せる。
  indirect case leftoverSession(
    TmuxSessionName,
    cause: Self,
    cleanupFailure: Self
  )
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
/// 単発で撃つ操作の target には必ず `=` を前置する。tmux 3.4 の実測では
/// `has-session -t awt-probe` が `awt-probe-deadbeef` にヒットして exit 0 になる
/// (候補が1つに絞れるときだけ前方一致する)。ユーザー自身の session と名前空間を共有する
/// (§4.1) 以上、前方一致は他人の session を消しかねない。`=` は大文字小文字も区別する。
///
/// `create` が session を作った後の操作は、名前ではなく `#{session_id}` (`$N`) で狙う。
/// **名前に `=` を足すだけでは防ぎ切れない**ためである (tmux 3.4 実測:
/// `new-window -d -t "=awt-tgt-lon"` は `awt-tgt-long` に window を作った)。`$N` は前方一致せず、
/// 対象が消えていれば `can't find session: $N` で止まる (実測)。
///
/// - Note: session 名そのものの検証は行わない。`TmuxSessionName` は安定 ID からの導出でしか
///   作れず (memberwise initializer は合成されない)、§3.5 の導出規則から `rawValue` は常に
///   `[A-Za-z0-9_-]+` になる。tmux 出力から parse する `PaneID` と違って第二の出所が無いので、
///   ここで再検証しても「§3.5 が広がったときに Adapters 側だけが古い規則で弾く」ドリフトしか
///   生まない。
public struct TmuxSessionOperations: Sendable {
  /// 設計書 §4.4 の製品既定。pane 単位でおよそ25MB (174桁 × 10000行) を見込む。
  public static let defaultHistoryLimit = 10_000
  /// 設計書 §4.2 の製品既定。全クライアントが全内容を見られるのはこれだけ。
  public static let defaultWindowSize = TmuxWindowSize.smallest
  /// tmux 3.4 実測: `-1` は `value is too small: -1`、`2147483648` は `value is too large: ...`。
  /// `0` と `2147483647` は rc=0 で通る。
  public static let historyLimitRange = 0...Int(Int32.max)

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
      return try await probe(session) == .present
    } catch {
      switch error {
      case .serverNotRunning: return false
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
  /// pane を作り直さないため履歴容量は `2000` のままだった。
  ///
  /// `window-size` は window option であり、`set-option -t <session>` はその時点の現在 window に
  /// しか効かない (実測)。そのため設定は最初の window を捨てた**あと**、残った window に対して
  /// 行う。順序を入れ替えると、捨てる window に設定して消える。
  ///
  /// - Important: **server が動いていなければ session を作らず `serverNotRunning` を返す。**
  ///   起動できないからではなく、起動してしまうと `TmuxRunner` が渡す限定環境
  ///   (`LC_ALL=C` と `HOME` / `PATH` / `TMUX_TMPDIR` だけ) がユーザーの既定 server の
  ///   global environment になり、ユーザー自身が素の端末で作る pane まで巻き込むからである。
  ///   どんな環境で server を起動するかは Issue #61 が扱う。
  /// - Important: 探索から作成までの競合窓は残る。server の存在を確かめてから `new-session` を
  ///   撃つまでの間に server が落ちると、`new-session` が server を起動してしまう。連鎖の先頭に
  ///   `has-session` を置いても塞げないことは実測済み (server 不在の socket へ
  ///   `has-session ; new-session` を撃つと、tmux はコマンド列を実行する前に server を起動した)。
  /// - Note: `new-session` の後の失敗では、作った session を `$N` 指定で消してから原因を投げる。
  ///   後始末にも失敗したときだけ `leftoverSession` になる。
  /// - Note: 残る window の index は `base-index` に従う (既定 `0` なら 1、`base-index 1` なら 2。
  ///   いずれも実測)。指定は `<id>:^` と `<id>:` で行うので番号には依存しない。
  public func create(
    session: TmuxSessionName,
    workingDirectory: String,
    historyLimit: Int = Self.defaultHistoryLimit,
    windowSize: TmuxWindowSize = Self.defaultWindowSize
  ) async throws(TmuxSessionOperationError) {
    guard Self.historyLimitRange.contains(historyLimit) else {
      throw .invalidHistoryLimit(historyLimit)
    }
    guard Self.isSafeArgument(workingDirectory) else {
      throw .invalidWorkingDirectory(workingDirectory)
    }
    guard directoryExists(workingDirectory) else {
      throw .workingDirectoryNotFound(workingDirectory)
    }
    guard try await probe(session) == .absent else {
      throw .sessionAlreadyExists(session)
    }

    let created = try await run(
      [
        "new-session", "-d", "-s", session.rawValue, "-c", workingDirectory,
        "-P", "-F", "#{session_id}",
      ],
      session: session
    )

    var sessionID = created.stdout
    if sessionID.hasSuffix("\n") {
      sessionID.removeLast()
    }
    guard Self.isWellFormedSessionID(sessionID) else {
      // session ID を読めなくても session はできているので、完全一致の名前で後始末する。
      try await cleanUp(
        target: "=\(session.rawValue)",
        session: session,
        cause: .unexpectedSessionIDOutput(created.stdout)
      )
    }

    do {
      _ = try await run(
        [
          "set-option", "-t", sessionID, "history-limit", String(historyLimit),
          ";", "new-window", "-d", "-t", sessionID, "-c", workingDirectory,
          ";", "kill-window", "-t", "\(sessionID):^",
          ";", "set-option", "-w", "-t", "\(sessionID):", "window-size", windowSize.rawValue,
        ],
        session: session,
        messageTarget: sessionID
      )
    } catch {
      try await cleanUp(target: sessionID, session: session, cause: error)
    }
  }

  /// - Note: 「もう無かった」を成功へ丸めず `sessionNotFound` で返す。server ごと落ちていた
  ///   場合も同様に `serverNotRunning` を返す。どちらを成功と見なすかは Close の選択肢
  ///   (§3.4) ごとに違うため、ここでは決めない。
  public func kill(session: TmuxSessionName) async throws(TmuxSessionOperationError) {
    _ = try await run(["kill-session", "-t", "=\(session.rawValue)"], session: session)
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

  private enum SessionPresence: Sendable, Equatable {
    case present
    case absent
  }

  /// server が動いていなければ `serverNotRunning` を投げる。`exists` は畳み、`create` は畳まない。
  private func probe(
    _ session: TmuxSessionName
  ) async throws(TmuxSessionOperationError) -> SessionPresence {
    do {
      _ = try await run(["has-session", "-t", "=\(session.rawValue)"], session: session)
      return .present
    } catch {
      switch error {
      case .sessionNotFound: return .absent
      default: throw error
      }
    }
  }

  /// 後始末できたら `cause` を、できなければ `leftoverSession` を投げる。正常に返ることは無い。
  private func cleanUp(
    target: String,
    session: TmuxSessionName,
    cause: TmuxSessionOperationError
  ) async throws(TmuxSessionOperationError) -> Never {
    do {
      _ = try await run(
        ["kill-session", "-t", target],
        session: session,
        messageTarget: Self.messageTarget(of: target)
      )
    } catch {
      // 既に消えているなら後始末の目的は果たされている。
      if case .sessionNotFound = error {
        throw cause
      }
      throw .leftoverSession(session, cause: cause, cleanupFailure: error)
    }
    throw cause
  }

  /// `messageTarget` は tmux のメッセージに現れる target 表記。`=` は剥がされ (実測)、
  /// session ID 指定では `$N` がそのまま出る。
  private func run(
    _ arguments: [String],
    session: TmuxSessionName?,
    messageTarget: String? = nil
  ) async throws(TmuxSessionOperationError) -> ProcessRunResult {
    do {
      return try await runner.run(arguments: arguments)
    } catch {
      throw Self.mapFailure(error, session: session, target: messageTarget ?? session?.rawValue)
    }
  }

  private static func mapFailure(
    _ error: TmuxRunnerError,
    session: TmuxSessionName?,
    target: String?
  ) -> TmuxSessionOperationError {
    guard case .commandFailed(let exitCode, _, let stderr) = error, exitCode == 1 else {
      return .tmux(error)
    }
    if isServerAbsent(stderr) {
      return .serverNotRunning
    }
    guard let session, let target else {
      return .tmux(error)
    }
    // stderr の文字列一致が locale で壊れないのは、tmux が NLS を持たないため
    // (実測: `nm -u` に gettext のシンボルが無く、メッセージは C の文字列リテラル)。
    switch stderr {
    case "can't find session: \(target)\n": return .sessionNotFound(session)
    case "duplicate session: \(target)\n": return .sessionAlreadyExists(session)
    default: return .tmux(error)
    }
  }

  /// tmux 3.4 は server 不在を socket ファイルの状態で2通りに書き分ける (実測)。
  ///
  /// - 起動後に終了して socket が残っている: `no server running on <path>\n`
  /// - 一度も起動しておらず socket が無い: `error connecting to <path> (No such file or directory)\n`
  ///
  /// 後者は tmux を使ったことがないユーザーの初回状態であり、§3.3 の入口の正常系である。
  /// ただし `error connecting to ` の前置きは server 不在以外にも使われるため、末尾の errno まで
  /// 見て畳む。畳んではいけない例 (いずれも実測):
  /// `... (File name too long)` / `... (Socket operation on non-socket)`
  private static func isServerAbsent(_ stderr: String) -> Bool {
    if stderr.hasPrefix("no server running on ") {
      return true
    }
    return stderr.hasPrefix("error connecting to ")
      && stderr.hasSuffix(" (No such file or directory)\n")
  }

  /// tmux は argv をコマンド列として解釈するため、末尾が `;` の引数はそこでコマンドが切れて値から
  /// 落ち、末尾が `\` の引数は escape として食われる。どちらも tmux 3.4 実測で、**単一コマンドでも
  /// 起きる** (`-c "<dir>;"` は `<dir>` に、`-c "<dir>\"` は `$HOME` に pane を作って rc=0 を返した)。
  /// 実在を検証したうえで別のディレクトリに pane を作り成功を返すのは、この検証が防ごうとしている
  /// 「黙った成功」そのものなので、tmux へ渡す前に弾く。途中の `;` は値に残る (実測) ので弾かない。
  private static func isSafeArgument(_ value: String) -> Bool {
    guard let last = value.last else { return false }
    return last != ";" && last != "\\"
  }

  /// 値の出どころは `#{session_id}` だけだが、`<id>:^` のような target 構文へ埋め込むため、
  /// tmux が返した形であることを渡す前に確かめる (`TmuxPaneOperations` の `PaneID` と同じ理由)。
  private static func isWellFormedSessionID(_ value: String) -> Bool {
    guard value.hasPrefix("$") else { return false }
    let digits = value.dropFirst()
    guard !digits.isEmpty else { return false }
    return digits.allSatisfy { $0.isASCII && $0.isNumber }
  }

  private static func messageTarget(of target: String) -> String {
    target.hasPrefix("=") ? String(target.dropFirst()) : target
  }
}
