import Foundation
import TerminalCore

/// 複数 pane の `capture-pane` を tmux 1プロセスへまとめるための argv 組み立てと復号
/// (Issue #239 R2)。tmux は `;` を挟んだコマンド列を1起動で順に実行し、stdout も引数の
/// 順どおりに並ぶ (tmux 3.4 で実測)。
enum TmuxPaneScreenBatch {
  /// マーカーは capture の**後**に置く。実測した事実は「列は失敗した地点で止まり、そこまでの
  /// stdout だけが残る」「stdout は引数の順に並ぶ」の2つ (tmux 3.4)。ここから、マーカーを前に
  /// 置くと最後の pane の画面が完全かどうかを stdout から判定できず、途中で切れた画面を
  /// 完全な画面として配ってしまう。後に置けば、マーカーが届いた pane だけが完全だと分かり、
  /// 失敗した pane は**最後に完成した pane の次**に決まる。
  static func arguments(panes: [PaneID], nonce: String) -> [String] {
    var arguments: [String] = []
    for pane in panes {
      if !arguments.isEmpty { arguments.append(";") }
      arguments.append(contentsOf: ["capture-pane", "-e", "-p", "-t", pane.rawValue])
      arguments.append(";")
      arguments.append(contentsOf: [
        "display-message", "-t", pane.rawValue, "-p", "\(nonce) #{pane_id}",
      ])
    }
    return arguments
  }

  /// バッチごとに作り直す。画面には過去のバッチのマーカーが残り得るため、固定文字列だと
  /// capture の中身をマーカーと読み違える。`display-message -p` はテンプレートを strftime
  /// 展開する (tmux 3.4 で実測: `MARKER-%0-end` → `MARKER--end`) ので、`%` を含めない。
  static func makeNonce() -> String {
    "AWT" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  /// `expected` の先頭から、マーカーで閉じられた pane を順に返す。閉じられていない末尾
  /// (= 列が失敗した地点) は含めない。
  ///
  /// 各 pane の画面は、単独で `capture-pane -e -p -t <pane>` を撃った stdout と
  /// バイト一致する (tmux 3.4 で実測)。`capture-pane -p` の stdout は必ず改行で終わるため、
  /// 行を再結合したあとに改行を1つ足して復元する。
  static func parse(
    stdout: String, nonce: String, expected: [PaneID]
  ) -> [(pane: PaneID, screen: String)] {
    let markerPrefix = nonce + " "
    var captured: [(pane: PaneID, screen: String)] = []
    var pending: [Substring] = []
    var nextIndex = 0

    var lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
    // 末尾の改行が作る空要素はレコードではない。
    if stdout.hasSuffix("\n") { lines.removeLast() }

    for line in lines {
      guard line.hasPrefix(markerPrefix) else {
        pending.append(line)
        continue
      }
      guard nextIndex < expected.count,
        line.dropFirst(markerPrefix.count) == expected[nextIndex].rawValue
      else {
        // 並びが引数と食い違ったら、そこから先は解釈しない。捏造した画面を配るより
        // 「取れなかった」に倒す。
        return captured
      }
      captured.append(
        (expected[nextIndex], pending.isEmpty ? "" : pending.joined(separator: "\n") + "\n"))
      pending.removeAll(keepingCapacity: true)
      nextIndex += 1
    }
    return captured
  }
}
