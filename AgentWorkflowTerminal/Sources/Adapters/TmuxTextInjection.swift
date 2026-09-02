import Darwin
import Foundation
import TerminalCore

public enum TmuxTextInjectionError: Error, Sendable, Equatable {
  /// `%N` 形式でない値。tmux へ渡す前に弾いた場合だけこれになる。
  case invalidPaneID(PaneID)
  /// bracketed paste から抜け出し得る文字を本文に見つけた。tmux を起動する前に弾く。
  /// `unicodeScalarOffset` は `text.unicodeScalars` の先頭からの位置で、UTF-8 でも UTF-16 でも
  /// 文字数でもない。呼び出し側が該当箇所を指し示せるように載せている。
  /// テキストを加工して返す API は用意しない。どう直すかは呼び出し側の判断。
  case unsafeControlCharacter(scalar: Unicode.Scalar, unicodeScalarOffset: Int)
  /// 注入テキストを載せる一時ファイルを作れなかった。
  case temporaryFileCreationFailed(path: String)
  /// tmux 3.4 実測: 対象 pane が無いと exit 1 / stderr `can't find pane: %N\n`。1バイトも届かない。
  case paneNotFound(PaneID)
  /// 対象 pane が copy-mode 等の pane mode にいたため送らなかった。1バイトも届いていない。
  ///
  /// **copy-mode では bracketed paste が効かない。** tmux 3.4 は mode 中の pane に対して
  /// `paste-buffer -p` の括りを付けず、LF → CR 変換だけが残るため、本文が丸ごと Enter として
  /// 配達される (実測: copy-mode にした zsh 5.9 の pane で、注入したコマンドが実行された)。
  /// `paneInputDisabled` と分けているのは、ユーザーが取る復旧操作が違うため
  /// (mode を抜ける / pane の入力を有効に戻す)。こちらは scroll やマウス操作で日常的に起こる。
  case paneInCopyMode(PaneID)
  /// 対象 pane が入力を受け付けない設定 (`select-pane -d`) だったため送らなかった。
  ///
  /// tmux 3.4 実測: この pane へ `paste-buffer -p -d` を投げると **exit 0 を返して buffer まで
  /// 消える一方、pane には0バイトしか届かない**。成功として返すと、呼び出し側が「送った」と
  /// 表示したまま本文が消える。
  case paneInputDisabled(PaneID)
  /// 上記へ分類しなかった失敗。終了コード・stdout・stderr を加工せずに保持する。
  /// tmux の非ゼロ終了を「正常状態」と「エラー」へ一般に分類するのは Issue #62 の担当。
  /// 例: 死んだ pane (`remain-on-exit`) は exit 1 / `target pane has exited` でここへ来る (実測)。
  case tmux(TmuxRunnerError)
}

/// 設計書 §9.2 (Diff review コメントを実装 Agent の pane へ送る) と §10 (Ask Agent) が要る、
/// pane へのテキスト注入。
///
/// **注入は「送信」ではない。** 本文の改行を Enter として実行させる機能はここに無い。実行するか
/// どうかは UI 側の判断で、別の操作として設計する (この型は実行手段を一切持たない)。
/// 方式は `load-buffer` + `paste-buffer -p` で固定する。`send-keys -l` は改行がそのまま実行に
/// なるため使わない (Spikes/gate1/README.md §8.8、docs/coding-guidelines.md §6 の申し送り #5)。
///
/// - Important: **「安全に貼れるか」は受け側アプリの属性ではなく、pane のその瞬間の状態である。**
///   tmux 3.4 が `paste-buffer -p` に `ESC[200~` / `ESC[201~` を付けるのは、pane が今まさに
///   DECSET 2004 を立てているときだけで、付かないときも本文の LF → CR 変換は残るため全行が
///   Enter として配達される。同じアプリでも状態次第で結果が変わる (実測: bracketed paste に
///   対応した vim 9.1 でも、normal mode では 2004 が立っておらず、注入した `:!touch …` が
///   実行された)。したがって「Claude Code なら安全」のようなアプリ単位の判断は成り立たない。
///   この型が塞ぐのは、tmux の format で観測できる `pane_in_mode` と `pane_input_off` だけで、
///   **アプリ側が 2004 を立てているかは tmux 3.4 の format に無く、注入側から観測できない。**
///   その範囲は呼び出し側でも判定できないため、残存リスクとして受け入れている。
/// - Important: **注入テキストは一時的にディスクへ載る。** `ProcessRunning` は設計上、子プロセスへ
///   stdin を渡さない (`ProcessRunner.swift`) ため `load-buffer -` が使えず、所有者だけが読める
///   一時ファイルを経由する。ファイルは `inject` を抜けるときに消すが、プロセスが SIGKILL 等で
///   即死した場合は消えずに残る。
public struct TmuxTextInjection: Sendable {
  /// tmux の buffer 名と一時ファイル名の共通接頭辞。どちらも「この型が作った」と一目で分かる形に
  /// しておき、後始末に失敗した残骸の出どころを追えるようにする。名前には毎回新しい UUID を
  /// 付ける。固定名だと、同名の buffer を持つユーザーの内容を `load-buffer -b` が黙って上書きし、
  /// 後始末の削除で消してしまう。
  private static let resourceNamePrefix = "awt-inject-"

  /// 本文の一部として通す制御文字。改行・タブ・復帰は Diff review コメントの本文に現れる。
  private static let allowedControlScalars: Set<Unicode.Scalar> = ["\t", "\n", "\r"]

  private let runner: TmuxRunner
  private let temporaryDirectory: URL

  public init(runner: TmuxRunner) {
    self.init(runner: runner, temporaryDirectory: FileManager.default.temporaryDirectory)
  }

  /// `temporaryDirectory` を差し替えられるのは、path の format 展開 (`escapingFormats`) が
  /// 実際に `load-buffer` の引数へ効いていることをテストが `#` を含むディレクトリで確かめるため。
  init(runner: TmuxRunner, temporaryDirectory: URL) {
    self.runner = runner
    self.temporaryDirectory = temporaryDirectory
  }

  /// 空文字列は tmux を一度も起動せずに戻る。tmux 3.4 の `load-buffer` は空ファイルに対して
  /// exit 0 を返しながら buffer を作らず、続く `paste-buffer` が `no buffer` で失敗するため
  /// (実測)。その副作用として、空文字列のときだけ `pane` の**状態も存在も**確かめない
  /// (`%N` 形式かどうかの検査は行う)。
  public func inject(_ text: String, into pane: PaneID) async throws(TmuxTextInjectionError) {
    guard Self.isWellFormed(pane) else {
      throw .invalidPaneID(pane)
    }
    if let unsafe = Self.firstUnsafeControlScalar(in: text) {
      throw .unsafeControlCharacter(scalar: unsafe.scalar, unicodeScalarOffset: unsafe.offset)
    }
    guard !text.isEmpty else { return }

    let attempt = Attempt(pane: pane)
    let fileURL = temporaryDirectory.appending(path: Self.resourceNamePrefix + attempt.token)
    try Self.writeOwnerOnly(text, to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let outcome = await send(attempt, from: fileURL.path)
    // 成功経路では `paste-buffer -d` が既に消しているので `unknown buffer` になるだけ。
    await deleteBuffer(attempt.bufferName)
    if case .failure(let error) = outcome {
      throw error
    }
  }

  private func send(
    _ attempt: Attempt,
    from path: String
  ) async -> Result<Void, TmuxTextInjectionError> {
    do {
      _ = try await runner.run(
        arguments: ["load-buffer", "-b", attempt.bufferName, Self.escapingFormats(path)])
      _ = try await runner.run(arguments: attempt.gateArguments)
      return .success(())
    } catch {
      return .failure(attempt.mapFailure(error))
    }
  }

  /// buffer の後始末。`load-buffer` を投げた後は成功・失敗にかかわらず必ず通す。
  ///
  /// tmux 3.4 実測: `load-buffer` の読み取りはクライアント側で行われ、**データを送り終えた直後に
  /// クライアントを SIGKILL すると 20/20 で server に buffer が残った**。`TmuxRunner` の
  /// タイムアウトや Task キャンセルはまさにこの殺し方をするため、後始末を成功経路だけに
  /// 置くと注入本文を抱えた buffer が永久に残る。`paste-buffer -d` も、paste が成功したときしか
  /// buffer を消さない (実測)。
  ///
  /// キャンセルを継承しない Task で実行するのは、`ProcessRunning` がキャンセル済みの呼び出し元では
  /// プロセスを起動せず `.cancelled` を返すため。そのままでは「キャンセルされたときだけ buffer が
  /// 残る」ことになる。呼び出し元へ返すエラーはキャンセルのまま変えない
  /// (docs/coding-guidelines.md §1.4)。削除自体の失敗は返す値を変えない。
  private func deleteBuffer(_ bufferName: String) async {
    let runner = self.runner
    await Task.detached {
      _ = try? await runner.run(arguments: ["delete-buffer", "-b", bufferName])
    }.value
  }

  /// 所有者だけが読めるファイルを1回で作る。`O_EXCL` で必ず新規作成にし、mode を `open(2)` へ
  /// 渡してから `fchmod` で確定する。`fchmod` を重ねるのは、`open` の mode が umask で削られ、
  /// 別プロセスである tmux が読めなくなる場合があるため (umask はビットを足さないので、この間の
  /// 権限が 0600 より緩くなることはない)。fd に対して効かせるので path の差し替えは挟まらない。
  private static func writeOwnerOnly(
    _ text: String,
    to url: URL
  ) throws(TmuxTextInjectionError) {
    let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard descriptor >= 0, fchmod(descriptor, 0o600) == 0 else {
      if descriptor >= 0 {
        close(descriptor)
        try? FileManager.default.removeItem(at: url)
      }
      throw .temporaryFileCreationFailed(path: url.path)
    }
    let written = Data(text.utf8).withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return true }
      var offset = 0
      while offset < raw.count {
        let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
        guard count > 0 else {
          if errno == EINTR { continue }
          return false
        }
        offset += count
      }
      return true
    }
    close(descriptor)
    guard written else {
      try? FileManager.default.removeItem(at: url)
      throw .temporaryFileCreationFailed(path: url.path)
    }
  }

  /// tmux 3.4 実測: `load-buffer` の path 引数は format 展開される。`…/tst-#S.txt` を渡すと
  /// `#S` が session 名へ展開され、**実在する別のファイルを読み込んで exit 0 になった**。
  /// `TMPDIR` に `#` を含む値を置かれると、注入が謎の ENOENT になるだけでなく、細工次第で
  /// 別ファイルの中身を pane へ貼る経路になる。`#` を `##` にすると literal として扱われることを
  /// 実測で確認している。`~` は展開されない (実測) ので触らない。
  static func escapingFormats(_ path: String) -> String {
    path.replacingOccurrences(of: "#", with: "##")
  }

  /// bracketed paste には escape が無い。本文に `ESC[201~` があると受け側はそこで paste を
  /// 終わりと見なし、残りを打鍵として扱う。tmux は LF を CR (= Enter) にするため、残りの行は
  /// そのまま実行される (tmux 3.4 + zsh 5.9 で、注入テキスト中の `ESC[201~` に続くコマンドが
  /// 実行されることを実測)。
  ///
  /// 実測では zsh 5.9 が反応したのは `ESC[201~` ちょうどの並びだけ (`ESC[0201~` /
  /// `ESC[201;1~` では抜け出せなかった) だが、受け側の parser は注入側から分からない。
  /// 本文を黙って書き換えるとレビューコメントが壊れるため、削るのではなく拒否して
  /// 呼び出し側へ返す。
  private static func firstUnsafeControlScalar(
    in text: String
  ) -> (scalar: Unicode.Scalar, offset: Int)? {
    for (offset, scalar) in text.unicodeScalars.enumerated() {
      guard !allowedControlScalars.contains(scalar) else { continue }
      guard scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) else { continue }
      return (scalar, offset)
    }
    return nil
  }

  /// tmux の target 構文では `%N` 以外の文字列も session / window 名や glob として解釈され得る。
  /// `paste-buffer -t` にコマンド列を渡してもコマンドとしては実行されない (実測) が、無関係の
  /// session の pane へ本文を届けてしまう経路は残る。`TmuxPaneOperations` と同じ検査を通す。
  private static func isWellFormed(_ pane: PaneID) -> Bool {
    guard pane.rawValue.hasPrefix("%") else { return false }
    let digits = pane.rawValue.dropFirst()
    guard !digits.isEmpty else { return false }
    return digits.allSatisfy { $0.isASCII && $0.isNumber }
  }
}

extension TmuxTextInjection {
  /// 1回の注入が使う tmux 側の名前一式。3つとも同じ UUID から作り、残骸を1回の注入へ辿れるように
  /// しておく。sentinel を毎回変えるのは、固定名だと同名 buffer を持つユーザーのもとで
  /// `delete-buffer` が成功して exit 0 になり、「送らなかった」が成功に化けるため。
  fileprivate struct Attempt {
    let token = UUID().uuidString
    let pane: PaneID

    var bufferName: String { TmuxTextInjection.resourceNamePrefix + token }
    private var copyModeSentinel: String { "awt-refused-copy-mode-" + token }
    private var inputDisabledSentinel: String { "awt-refused-input-off-" + token }

    /// 受け側 pane の状態判定と paste を tmux 側の1コマンドに載せる。クライアントで状態を読んでから
    /// 貼ると、その間に pane が copy-mode へ入る TOCTOU が残るため
    /// (`TmuxPaneOperations.runZoomBranch` と同じ理由・同じ idiom)。
    ///
    /// 「送らなかった」分岐に存在しない buffer の削除を置くのは、**exit 0 で終わる分岐にすると
    /// 呼び出し側が成功と区別できなくなる**ため。tmux 3.4 実測では `list-panes -t %N -f 0` は
    /// exit 0 を返してしまい probe に使えず、`delete-buffer -b <存在しない名前>` は exit 1 と
    /// stderr `unknown buffer: <名前>` を返して if-shell 全体の終了コードへ伝わる。
    /// 入れ子にしているのは、`#{||:…}` の1条件では copy-mode と入力無効を呼び出し側が
    /// 区別できないため (分岐の引数の中では format が展開されず `syntax error` になる。実測)。
    ///
    /// 分岐はコマンド列としてパースされるので、検証していない `PaneID` を埋めるとコマンド注入に
    /// なる。埋めるのは `%N` 検査を通した pane と、自分で作った UUID だけ。注入する本文は
    /// buffer 経由で渡すので、ここには一切現れない。
    var gateArguments: [String] {
      let target = pane.rawValue
      let whenInputDisabled = "delete-buffer -b \(inputDisabledSentinel)"
      let paste = "paste-buffer -p -d -b \(bufferName) -t \(target)"
      return [
        "if-shell", "-F", "-t", target, "#{pane_in_mode}",
        "delete-buffer -b \(copyModeSentinel)",
        "if-shell -F -t \(target) '#{pane_input_off}' '\(whenInputDisabled)' '\(paste)'",
      ]
    }

    func mapFailure(_ error: TmuxRunnerError) -> TmuxTextInjectionError {
      guard case .commandFailed(let exitCode, _, let stderr) = error, exitCode == 1 else {
        return .tmux(error)
      }
      switch stderr {
      case "unknown buffer: \(copyModeSentinel)\n": return .paneInCopyMode(pane)
      case "unknown buffer: \(inputDisabledSentinel)\n": return .paneInputDisabled(pane)
      case "can't find pane: \(pane.rawValue)\n": return .paneNotFound(pane)
      default: return .tmux(error)
      }
    }
  }
}
