import TerminalCore

/// §12.7 の連携変数名。ハーネスは自分の pane (`$TMUX_PANE`) へ `tmux set-option -p` で書く。
public enum TmuxPaneSummaryOption {
  /// 書き手はハーネス。`<agent-pid> <text>`。
  public static let status = "@awt_status"
  /// 書き手はハーネス。`<agent-pid> <token>`。token は完了ごとに変える。
  public static let completion = "@awt_done"
  /// 書き手はアプリだけ。`<text>`。
  public static let purpose = "@awt_purpose"
}

/// §12.7 の連携変数を pane 一覧と同じ1回の `list-panes` で読む部分。
extension TmuxListPanes {
  /// `format` の後ろに §12.7 の連携変数 (`@awt_status` / `@awt_done` / `@awt_purpose`) を
  /// 1フィールドずつ足したもの。値はハーネスやユーザーが自由に書けるので、`format` の
  /// フィールドと違って区切りを壊す値が現実に入り得る (#72 と同じ機序)。そこで各フィールドを
  /// tmux 側で次の順に判定し、先頭1文字の旗で結果を区別する (3.4 / 3.7c で実測)。
  ///
  /// 1. `#{n:}` (UTF-8 のバイト数) が `summaryValueByteLimit` を超える → `X`。
  ///    `ProcessRunner` の出力上限を1つの pane の値で使い切り、全 pane の観測を失うのを防ぐ。
  /// 2. LF・CR・0x1F のいずれかを含む → `L`。LF は両版とも生で出て行を割り、0x1F は区切りと
  ///    同じ形 (3.4 = `\037`、3.7c = 生) になる。CR は 3.7c が生で出し、最後のフィールドの末尾に
  ///    あると行末の LF と1つの書記素 (`\r\n`) になって、出力末尾の改行判定を外す (実測: 偽の
  ///    parse failure が1件出た)。判定は glob (`m:`) で行う — regex (`m/r:`) は不正 UTF-8 を
  ///    含む値に一致せず、`\xff` + LF を素通しした (実測)。glob は一致した。
  /// 3. regex `^.*$` に一致しない → `U`。不正 UTF-8 では regex が何にも一致せず、
  ///    **`s/\\/\\\\/` の二重化も黙って何もしない** (実測: `\xff\037x\` が単独の `\` のまま
  ///    出た)。二重化されない `\037` は区切りに読まれるので、二重化と同じ regex 経路で
  ///    先に弾く。
  /// 4. それ以外 → `v` + 二重化した値。他の生フィールドと同じく偶数列の backslash と出力段の
  ///    escape (`\$`、named、`\ooo`、いずれも 3.4 のみ) だけになる。3.7c の `pane_title`
  ///    と違い、ユーザー変数の展開は両版とも backslash を二重化しない (実測)。
  ///
  /// 旗は常に付くので、空 (`v` だけ) と未設定も同じ `v` になる。tmux は両者を区別しない。
  public static let formatWithSummary = [
    format,
    summaryField(TmuxPaneSummaryOption.status),
    summaryField(TmuxPaneSummaryOption.completion),
    summaryField(TmuxPaneSummaryOption.purpose),
  ].joined(separator: formatSeparator)

  /// `#{n:}` の単位はバイト。§12.7 の概要は1行の短文で、日本語 (3バイト/字) でも約340字。
  public static let summaryValueByteLimit = 1024

  private static func summaryField(_ option: String) -> String {
    #"#{?#{e|>|:#{n:\#(option)},\#(summaryValueByteLimit)},X,"#
      + "#{?#{m:*[\n\r\u{1F}]*,#{\(option)}},L,"
      + #"#{?#{m/r:^.*$,#{\#(option)}},v#{s/\\/\\\\/:\#(option)},U}}}"#
  }

  /// `formatWithSummary` で読んだ1行。連携変数のフィールドが読めなくても pane は失敗にせず、
  /// その変数だけを `.unreadable` にする。
  public static func parseWithSummary(line: String) throws(TmuxListPanesParseError) -> TmuxPane {
    let encodedFields = splitEncodedFields(line)
    guard encodedFields.count == paneFieldCount + 3 else {
      throw .invalidFieldCount(actual: encodedFields.count)
    }
    let summary = encodedFields[paneFieldCount...].map(decodeSummaryField)
    return try parse(
      paneFields: Array(encodedFields[..<paneFieldCount]),
      summaryReadings: PaneSummaryReadings(
        status: summary[0], completion: summary[1], purpose: summary[2]))
  }

  /// `tmux list-panes -F formatWithSummary` の stdout 用。連携変数の値は LF も CR も含まない形で
  /// 出る (`formatWithSummary`) ので、LF をレコード終端とする前提は `format` と同じに保てる。
  public static func parseWithSummary(output: String) -> TmuxListPanesParseResult {
    parse(output: output, line: parseWithSummary(line:))
  }

  /// 旗の意味は `formatWithSummary`。旗が1文字目に固定されているので、値がどんな文字列でも
  /// 旗を偽装できない。
  ///
  /// 旗はバイトで見る。`Character` で見ると、値が結合文字で始まるとき旗と1つの書記素になり
  /// (`v` + U+0301)、読める値を落とす。
  private static func decodeSummaryField(_ field: String) -> PaneUserOptionReading {
    let isFlagOnly = field.utf8.count == 1
    switch field.utf8.first {
    case UInt8(ascii: "v"):
      do {
        return .value(try decodeRawField(String(decoding: field.utf8.dropFirst(), as: UTF8.self)))
      } catch {
        return .unreadable(.malformedOutput)
      }
    case UInt8(ascii: "X") where isFlagOnly: return .unreadable(.tooLong)
    case UInt8(ascii: "L") where isFlagOnly: return .unreadable(.containsLineBreakOrUnitSeparator)
    case UInt8(ascii: "U") where isFlagOnly: return .unreadable(.invalidUTF8)
    default: return .unreadable(.malformedOutput)
    }
  }
}

public enum TmuxPanePurposeWriterError: Error, Sendable, Equatable {
  case invalidPaneID(PaneID)
  /// 目的は1行 (§12.7)。改行を1行へ畳むなどの正規化はせず、呼び出し側へ返す。判定は読み取り側と
  /// 同じ `PaneSummaryFormatViolation.breaksSingleLine`。
  case containsLineBreakOrControlCharacter
  case endsWithSemicolon
  /// 読み取り側 (`TmuxListPanes.formatWithSummary`) が値を落とす長さを書かない。
  case tooLong(byteCount: Int, limit: Int)
  case tmux(TmuxRunnerError)
}

/// 手入力の目的 (`@awt_purpose`) を書く・消す (§12.7 / §13)。アプリは永続化しない —
/// pane option なので Agent の再起動を越えて残り、pane が閉じるか server が終わると消える。
public struct TmuxPanePurposeWriter: Sendable {
  private let runner: TmuxRunner

  public init(runner: TmuxRunner) {
    self.runner = runner
  }

  /// 空文字と空白だけの文字列は削除と同じ (読み取り側がどちらも「未設定」と扱うため)。
  public func setPurpose(
    _ text: String, of pane: PaneID
  ) async throws(TmuxPanePurposeWriterError) {
    guard TmuxCapturePane.isWellFormed(pane) else { throw .invalidPaneID(pane) }
    if text.allSatisfy(\.isWhitespace) {
      try await clearPurpose(of: pane)
      return
    }
    guard !text.unicodeScalars.contains(where: PaneSummaryFormatViolation.breaksSingleLine) else {
      throw .containsLineBreakOrControlCharacter
    }
    // tmux は argv 要素の末尾の `;` をコマンド区切りとして取り、`--` でも防げない (3.4 / 3.7c
    // とも実測: `foo;` は `foo`、`a\;` は `a;`、`end;;` は `end;` で保存され、`;` 単独は失敗)。
    // 黙って削ると書いた値と保存される値がずれるので拒否する。
    guard !text.hasSuffix(";") else { throw .endsWithSemicolon }
    let byteCount = text.utf8.count
    guard byteCount <= TmuxListPanes.summaryValueByteLimit else {
      throw .tooLong(byteCount: byteCount, limit: TmuxListPanes.summaryValueByteLimit)
    }
    // `--` は値が `-` で始まっても option として読ませないため。3.4 / 3.7c とも、無くても
    // `@awt_purpose -u` の `-u` は値として入った (実測) が、tmux の引数解析に依存しない。
    try await run([
      "set-option", "-p", "-t", pane.rawValue, "--", TmuxPaneSummaryOption.purpose, text,
    ])
  }

  public func clearPurpose(of pane: PaneID) async throws(TmuxPanePurposeWriterError) {
    guard TmuxCapturePane.isWellFormed(pane) else { throw .invalidPaneID(pane) }
    try await run(["set-option", "-p", "-u", "-t", pane.rawValue, TmuxPaneSummaryOption.purpose])
  }

  private func run(_ arguments: [String]) async throws(TmuxPanePurposeWriterError) {
    do {
      _ = try await runner.run(arguments: arguments)
    } catch {
      throw .tmux(error)
    }
  }
}
