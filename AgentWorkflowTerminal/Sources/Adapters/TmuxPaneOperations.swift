import Foundation
import TerminalCore

public enum TmuxPaneOperationError: Error, Sendable, Equatable {
  /// `%N` 形式でない値。tmux へ渡す前に弾いた場合だけこれになる。
  case invalidPaneID(PaneID)
  /// tmux 3.4 実測: この型が送る引数では、6操作すべてが exit 1 と stderr
  /// `can't find pane: %N\n` を返す (zoom 系がそうなる条件は `zoom` 側のコメントを参照)。
  /// 「対象が既に無い」を成功へ丸めず値で返すのは、分割には返す `PaneID` が無く、選択・zoom も
  /// 要求した状態にならないため。close だけを成功と見なしたい呼び出し側は、この値で判別する。
  ///
  /// ただし **server ごと消えた経路はここへ来ない**。最後の pane を閉じるとその session が、
  /// それが最後の session なら server 自体も消え、以後の操作は exit 1 と
  /// `no server running on <socket path>\n` になって `.tmux(.commandFailed(...))` へ落ちる (実測)。
  case paneNotFound(PaneID)
  /// 分割の `-P -F '#{pane_id}'` が `%N` 以外を返した場合。原文を捨てずに載せる。
  case unexpectedSplitOutput(String)
  /// 上記へ分類しなかった失敗。終了コード・stdout・stderr を加工せずに保持する。
  /// tmux の非ゼロ終了を「正常状態」と「エラー」へ一般に分類するのは Issue #62 の担当。
  case tmux(TmuxRunnerError)
}

public enum TmuxPaneDirection: Sendable, Hashable, CaseIterable {
  case left
  case right
  case up
  case down

  fileprivate var flag: String {
    switch self {
    case .left: "-L"
    case .right: "-R"
    case .up: "-U"
    case .down: "-D"
    }
  }
}

/// 設計書 §4.1 が「最小限」と定めた操作 (分割 / 閉じる / 選択・移動 / zoom) だけを提供する。
/// rename・swap-pane・並べ替え・window / session 管理はここへ足さない。
///
/// 対象は `PaneID` (`%N`) のみで指定する。`%N` は tmux server 全体で一意で、別 session の pane も
/// session 指定なしに `-t %N` で指せることを実測で確認している。
/// ただし一意なのは **その server が生きている間だけ** で、server を立て直すと同じ socket 名でも
/// `%0` から振り直される (実測)。server を跨いで持ち越した `PaneID` は別の pane を指し得るため、
/// キャッシュしたまま `close` すると無関係の pane を閉じる。
public struct TmuxPaneOperations: Sendable {
  /// zoom 中の pane は必ずその window の active pane になるため、「%N が zoom されている」は
  /// この2条件の論理積で表せる。`if-shell -F` の条件式として tmux 側で評価させる。
  private static let paneIsZoomedFormat = "#{&&:#{pane_active},#{window_zoomed_flag}}"

  private let runner: TmuxRunner

  public init(runner: TmuxRunner) {
    self.runner = runner
  }

  /// 生成された pane が左右に並ぶ分割 (tmux の `split-window -h`)。
  /// 冪等ではない。呼ぶたびに pane が増える。
  /// window が zoom 中でも成功し、その副作用として window の zoom が解除される (実測)。
  public func splitLeftRight(pane: PaneID) async throws(TmuxPaneOperationError) -> PaneID {
    try await split(pane: pane, flag: "-h")
  }

  /// 生成された pane が上下に並ぶ分割 (tmux の `split-window -v`)。
  /// 冪等ではない。呼ぶたびに pane が増える。
  /// window が zoom 中でも成功し、その副作用として window の zoom が解除される (実測)。
  public func splitTopBottom(pane: PaneID) async throws(TmuxPaneOperationError) -> PaneID {
    try await split(pane: pane, flag: "-v")
  }

  /// window / session の最後の pane を閉じると、tmux 3.4 はその window / session ごと破棄し、
  /// それでも exit 0 を返す。破棄されたかは呼び出し側が別途観測する。
  public func close(pane: PaneID) async throws(TmuxPaneOperationError) {
    _ = try await run(["kill-pane", "-t", pane.rawValue], pane: pane)
  }

  /// 既に選択されている pane を指定しても exit 0 で、選択も変わらない (実測)。
  /// 表示中でない window の pane を指した場合に変わるのはその window の active pane だけで、
  /// session の current window は動かない (実測)。呼び出し側から見ると「選択したのに見えない」
  /// 状態になり得る。
  public func select(pane: PaneID) async throws(TmuxPaneOperationError) {
    _ = try await run(["select-pane", "-t", pane.rawValue], pane: pane)
  }

  /// tmux 3.4 は window の端で反対側へ回り込む (実測: 左右3分割の左端から `.left` すると
  /// 右端が選ばれる)。その方向に他の pane が1つも無いときだけ、回り込み先が自分自身になって
  /// 選択が変わらない。どちらも exit 0 なので、移動したかは戻り値では分からない。
  /// 必要なら呼び出し側が pane 一覧を読み直す。
  public func selectNeighbor(
    of pane: PaneID,
    direction: TmuxPaneDirection
  ) async throws(TmuxPaneOperationError) {
    _ = try await run(["select-pane", "-t", pane.rawValue, direction.flag], pane: pane)
  }

  /// `pane` をその window の zoom 対象にする。zoom 対象は tmux では常に active pane なので、
  /// `pane` は active にもなる。既に zoom 対象なら何も変えずに成功する。
  ///
  /// **成功は「zoom された」を意味しない。** pane が1つだけの window では、tmux 3.4 は zoom せず
  /// exit 0 を返す (実測)。zoom されたかを知りたい呼び出し側は `#{window_zoomed_flag}` を
  /// 読み直して確かめる。
  ///
  /// tmux 3.4 の `resize-pane -Z` はトグルで、非 active pane を指すとその pane を active に
  /// してから window の zoom を反転する。そのため「zoom 中の window で別 pane を zoom」は
  /// `resize-pane` 単体では zoom が解除されてしまう (実測)。
  public func zoom(pane: PaneID) async throws(TmuxPaneOperationError) {
    let target = pane.rawValue
    try await runZoomBranch(
      pane: pane,
      whenPaneIsZoomed: Self.existenceProbe(target),
      otherwise: "select-pane -t \(target) ; resize-pane -t \(target) -Z"
    )
  }

  /// `pane` 自身が zoom 対象のときだけ zoom を解除する。
  ///
  /// **別 pane が zoom 中のときは window の zoom を解除せず、何もせずに成功する。** 設計書 §4.1 の
  /// 「pane zoom」に合わせて対象を pane スコープに閉じているためで、window 単位で解除したい
  /// 呼び出し側は、zoom 中の pane (= その window の active pane) を自分で特定して渡す。
  public func unzoom(pane: PaneID) async throws(TmuxPaneOperationError) {
    let target = pane.rawValue
    try await runZoomBranch(
      pane: pane,
      whenPaneIsZoomed: "resize-pane -t \(target) -Z",
      otherwise: Self.existenceProbe(target)
    )
  }

  /// 条件判定と実行を `if-shell -F` の1コマンドに載せ、クライアント側で読んでから書く TOCTOU を
  /// 避ける。ただし同じ server へ他クライアントが同時に操作する競合までは解消していない。
  ///
  /// 分岐の2引数はコマンド列として tmux にパースされるため、`%N` の検証を通さずに `target` を
  /// 埋めるとコマンド注入になる (`%0 ; kill-pane -t %1` が実行されることを実測で確認)。
  /// 検証は `run` が tmux を起動する前に行う。
  private func runZoomBranch(
    pane: PaneID,
    whenPaneIsZoomed: String,
    otherwise: String
  ) async throws(TmuxPaneOperationError) {
    _ = try await run(
      [
        "if-shell", "-F", "-t", pane.rawValue, Self.paneIsZoomedFormat,
        whenPaneIsZoomed, otherwise,
      ],
      pane: pane
    )
  }

  /// 状態を変えずに対象 pane の存在だけを確かめるコマンド。`-f 0` は偽の filter なので1件も
  /// 出力せず、pane が無いときだけ `can't find pane` で失敗する (実測)。
  ///
  /// 「既に要求どおりの状態」の分岐にこれを置くのは、`if-shell -F` の条件式が対象 pane を
  /// 解決できなくても失敗せず `0` へ展開されるため (実測)。分岐を空にすると、存在しない pane への
  /// zoom 解除だけが exit 0 になり、他の5操作と不在の扱いが揃わなくなる。
  private static func existenceProbe(_ target: String) -> String {
    "list-panes -t \(target) -f 0"
  }

  private func split(
    pane: PaneID,
    flag: String
  ) async throws(TmuxPaneOperationError) -> PaneID {
    let result = try await run(
      ["split-window", "-t", pane.rawValue, flag, "-P", "-F", "#{pane_id}"],
      pane: pane
    )
    // 実測の stdout は `%N` + LF ちょうど1行。
    var stdout = result.stdout
    if stdout.hasSuffix("\n") {
      stdout.removeLast()
    }
    let created = PaneID(rawValue: stdout)
    guard Self.isWellFormed(created) else {
      throw .unexpectedSplitOutput(result.stdout)
    }
    return created
  }

  private func run(
    _ arguments: [String],
    pane: PaneID
  ) async throws(TmuxPaneOperationError) -> ProcessRunResult {
    guard Self.isWellFormed(pane) else {
      throw .invalidPaneID(pane)
    }
    do {
      return try await runner.run(arguments: arguments)
    } catch {
      throw Self.mapFailure(error, pane: pane)
    }
  }

  private static func mapFailure(
    _ error: TmuxRunnerError,
    pane: PaneID
  ) -> TmuxPaneOperationError {
    guard case .commandFailed(let exitCode, _, let stderr) = error else {
      return .tmux(error)
    }
    guard exitCode == 1, stderr == "can't find pane: \(pane.rawValue)\n" else {
      return .tmux(error)
    }
    return .paneNotFound(pane)
  }

  /// tmux の target 構文では `%N` 以外の文字列も session / window 名や glob として解釈され得る。
  /// 値の出どころは `#{pane_id}` だけという契約 (`PaneID` の定義) を、tmux へ渡す前に確認する。
  private static func isWellFormed(_ pane: PaneID) -> Bool {
    guard pane.rawValue.hasPrefix("%") else { return false }
    let digits = pane.rawValue.dropFirst()
    guard !digits.isEmpty else { return false }
    return digits.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
