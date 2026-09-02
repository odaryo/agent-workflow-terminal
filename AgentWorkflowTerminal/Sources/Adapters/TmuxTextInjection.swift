import Foundation
import TerminalCore

public enum TmuxTextInjectionError: Error, Sendable, Equatable {
  /// `%N` 形式でない値。tmux へ渡す前に弾いた場合だけこれになる。
  case invalidPaneID(PaneID)
  /// bracketed paste から抜け出し得る文字を本文に見つけた。tmux を起動する前に弾く。
  /// 値は最初に見つかった1文字で、テキストは加工せず呼び出し側へ判断を返す。
  case unsafeControlCharacter(Unicode.Scalar)
  /// 注入テキストを載せる一時ファイルを作れなかった。
  case temporaryFileCreationFailed(path: String)
  /// tmux 3.4 実測: 対象 pane が無いと `paste-buffer` は exit 1 と stderr
  /// `can't find pane: %N\n` を返す。このとき pane へは1バイトも届いていない。
  case paneNotFound(PaneID)
  /// 上記へ分類しなかった失敗。終了コード・stdout・stderr を加工せずに保持する。
  /// tmux の非ゼロ終了を「正常状態」と「エラー」へ一般に分類するのは Issue #62 の担当。
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
/// - Important: **注入テキストは一時的にディスクへ載る。** `ProcessRunning` は設計上、子プロセスへ
///   stdin を渡さない (`ProcessRunner.swift`) ため `load-buffer -` が使えず、所有者だけが読める
///   一時ファイルを経由する。ファイルは成功・失敗のどちらでも `inject` を抜けるときに消すが、
///   Diff review コメントや Ask Agent の本文がその間ディスク上に存在する。
/// - Important: **受け側が bracketed paste に対応していなければ、注入したコマンドは実行され得る。**
///   tmux 3.4 は `-p` を付けても、pane のアプリが DECSET 2004 を有効にしているときだけ
///   `ESC[200~` / `ESC[201~` で括る。有効でない pane へは括りなしで送り、しかも本文の LF は
///   常に CR (= Enter) へ変換して届ける (実測)。実測例: macOS 標準の bash 3.2 では注入した
///   1行目が実行され、zsh 5.9 では実行されず行編集バッファに入るだけだった。
///   受け側が対応しているかは注入側から判定できないため、この型では解決しない。
public struct TmuxTextInjection: Sendable {
  /// tmux 3.4 実測: 名前付き buffer はユーザーの無名 buffer stack (`buffer0`…) の番号を動かさない。
  /// 名前は注入ごとに一意にする。固定名だと、同名の buffer を持つユーザーの内容を
  /// `load-buffer -b` が黙って上書きし、後始末の削除で消してしまう。
  private static let bufferNamePrefix = "awt-inject-"
  private static let temporaryFileNamePrefix = "awt-inject-"

  /// 本文の一部として通す制御文字。改行・タブ・復帰は Diff review コメントの本文に現れる。
  private static let allowedControlScalars: Set<Unicode.Scalar> = ["\t", "\n", "\r"]

  private let runner: TmuxRunner

  public init(runner: TmuxRunner) {
    self.runner = runner
  }

  /// 空文字列は tmux を一度も起動せずに戻る。tmux 3.4 の `load-buffer` は空ファイルに対して
  /// exit 0 を返しながら buffer を作らず、続く `paste-buffer` が `no buffer` で失敗するため
  /// (実測)。その副作用として、空文字列のときだけ `pane` の**存在**は確かめない
  /// (`%N` 形式かどうかの検査は行う)。
  public func inject(_ text: String, into pane: PaneID) async throws(TmuxTextInjectionError) {
    guard Self.isWellFormed(pane) else {
      throw .invalidPaneID(pane)
    }
    if let unsafe = Self.firstUnsafeControlScalar(in: text) {
      throw .unsafeControlCharacter(unsafe)
    }
    guard !text.isEmpty else { return }

    let fileURL = FileManager.default.temporaryDirectory
      .appending(path: Self.temporaryFileNamePrefix + UUID().uuidString)
    // 作成と書き込みを分けると、中身の入っていない読める窓ができる。属性ごと1回で作る。
    guard
      FileManager.default.createFile(
        atPath: fileURL.path,
        contents: Data(text.utf8),
        attributes: [.posixPermissions: NSNumber(value: 0o600)]
      )
    else {
      throw .temporaryFileCreationFailed(path: fileURL.path)
    }
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let bufferName = Self.bufferNamePrefix + UUID().uuidString
    do {
      _ = try await runner.run(arguments: ["load-buffer", "-b", bufferName, fileURL.path])
    } catch {
      // 失敗した `load-buffer` は buffer を作らない (実測)。消しにいくと `unknown buffer` になる。
      throw Self.mapFailure(error, pane: pane)
    }

    do {
      _ = try await runner.run(
        arguments: ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", pane.rawValue])
    } catch {
      await deleteBuffer(bufferName)
      throw Self.mapFailure(error, pane: pane)
    }
  }

  /// tmux 3.4 実測: `paste-buffer -d` が buffer を消すのは paste が成功したときだけで、
  /// `can't find pane` で失敗した後には buffer が残る。失敗経路の後始末はここが担当する。
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

  private static func mapFailure(
    _ error: TmuxRunnerError,
    pane: PaneID
  ) -> TmuxTextInjectionError {
    guard case .commandFailed(let exitCode, _, let stderr) = error else {
      return .tmux(error)
    }
    guard exitCode == 1, stderr == "can't find pane: \(pane.rawValue)\n" else {
      return .tmux(error)
    }
    return .paneNotFound(pane)
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
  private static func firstUnsafeControlScalar(in text: String) -> Unicode.Scalar? {
    text.unicodeScalars.first {
      guard !allowedControlScalars.contains($0) else { return false }
      return $0.value < 0x20 || (0x7f...0x9f).contains($0.value)
    }
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
