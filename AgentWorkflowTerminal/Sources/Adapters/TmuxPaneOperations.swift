import Foundation
import TerminalCore

public enum TmuxPaneOperationError: Error, Sendable, Equatable {
  /// `%N` 形式でない値。tmux へ渡す前に弾いた場合だけこれになる。
  case invalidPaneID(PaneID)
  /// tmux 3.4 実測: この型が送る引数では、6操作すべてが exit 1 と stderr
  /// `can't find pane: %N\n` を返す (zoom 系がそうなる条件は `setZoom` 側のコメントを参照)。
  /// 「対象が既に無い」を成功へ丸めず値で返すのは、分割には返す `PaneID` が無く、選択・zoom も
  /// 要求した状態にならないため。close だけを成功と見なしたい呼び出し側は、この値で判別する。
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

  /// tmux の方向フラグは画面上の向きをそのまま指す (`-L` が左)。実測で確認済み。
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
  public func splitLeftRight(pane: PaneID) async throws(TmuxPaneOperationError) -> PaneID {
    try await split(pane: pane, flag: "-h")
  }

  /// 生成された pane が上下に並ぶ分割 (tmux の `split-window -v`)。
  /// 冪等ではない。呼ぶたびに pane が増える。
  public func splitTopBottom(pane: PaneID) async throws(TmuxPaneOperationError) -> PaneID {
    try await split(pane: pane, flag: "-v")
  }

  /// window / session の最後の pane を閉じると、tmux 3.4 はその window / session ごと破棄し、
  /// それでも exit 0 を返す。破棄されたかは呼び出し側が別途観測する。
  public func close(pane: PaneID) async throws(TmuxPaneOperationError) {
    _ = try await run(["kill-pane", "-t", pane.rawValue], pane: pane)
  }

  /// 既に選択されている pane を指定しても exit 0 で、選択も変わらない (実測)。
  public func select(pane: PaneID) async throws(TmuxPaneOperationError) {
    _ = try await run(["select-pane", "-t", pane.rawValue], pane: pane)
  }

  /// 指定方向に隣接 pane が無いとき、tmux 3.4 は選択を変えずに exit 0 を返す (実測)。
  /// 移動したかどうかは戻り値では分からないため、必要なら呼び出し側が pane 一覧を読み直す。
  public func selectNeighbor(
    of pane: PaneID,
    direction: TmuxPaneDirection
  ) async throws(TmuxPaneOperationError) {
    _ = try await run(["select-pane", "-t", pane.rawValue, direction.flag], pane: pane)
  }

  /// `isZoomed` が真なら「`pane` がその window の zoom 対象である」状態、偽ならその否定にする。
  /// zoom 対象は tmux では常に active pane なので、真にすると `pane` は active にもなる。
  /// 偽の指定は `pane` 自身が zoom 対象のときだけ解除する。別 pane が zoom 中なら `pane` は
  /// 既に zoom されていないため何もしない。
  ///
  /// tmux 3.4 の `resize-pane -Z` はトグルで、非 active pane を指すとその pane を active に
  /// してから window の zoom を反転する。そのため「zoom 中の window で別 pane を zoom」は
  /// `resize-pane` 単体では zoom が解除されてしまう (実測)。ここでは条件判定と実行を
  /// `if-shell -F` の1コマンドに載せ、クライアント側で読んでから書く TOCTOU を避けている。
  /// ただし同じ server へ他クライアントが同時に操作する競合までは解消していない。
  public func setZoom(_ isZoomed: Bool, pane: PaneID) async throws(TmuxPaneOperationError) {
    let target = pane.rawValue
    // `if-shell` の分岐はコマンド列として tmux にパースされるため、`%N` の検証を通さずに
    // 埋めるとコマンド注入になる (`%0 ; kill-pane -t %1` が実行されることを実測で確認)。
    let change = "select-pane -t \(target) ; resize-pane -t \(target) -Z"
    let branches =
      isZoomed
      ? [Self.existenceProbe(target), change]
      : ["resize-pane -t \(target) -Z", Self.existenceProbe(target)]
    _ = try await run(
      ["if-shell", "-F", "-t", target, Self.paneIsZoomedFormat] + branches,
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
