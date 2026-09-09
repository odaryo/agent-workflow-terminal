import Foundation
import TerminalCore

/// 複数 pane の `capture-pane` を tmux 1プロセスへまとめるための argv 組み立てと復号
/// (Issue #239 R2)。tmux は `;` を挟んだコマンド列を1起動で順に実行し、stdout も引数の
/// 順どおりに並ぶ (tmux 3.4 で実測)。
enum TmuxPaneScreenBatch {
  struct Entry: Sendable, Equatable {
    let pane: PaneID
    let screen: String
    let title: String
  }

  /// marker は pane ID に加えて title も運ぶ。`PaneSnapshot.title` を使うと、`AgentAdapter` の
  /// 既定 `observations(of:)` が毎周期同じ snapshot 値を渡すため title が観測開始時刻で凍る
  /// (`CodexAdapter` は title の spinner を画面判定より前に短絡するので Working に貼り付く)。
  /// 相乗りなら追加の外部プロセス起動は 0 で、鮮度は画面と完全に一致する。
  ///
  /// 区切りと escape は `list-panes` と同じ規則で、復号も `TmuxListPanes` に委ねる。
  /// tmux 3.4 実測: 区切りの Unit Separator は `\037` として出力され、
  /// `#{s/\\/\\\\/:pane_title}` は値の backslash を二重化し、出力段が `$` の前に `\` を足す
  /// (`back\slash $dollar` → `back\\slash \$dollar`)。
  ///
  /// - Note: `display-message -p` は template の**リテラル部**を strftime 展開する (実測)。
  ///   一方**値**は展開されない — title を `pct %H %% %0 end` にして読み戻すと文字列のまま
  ///   返った (tmux 3.4 実測)。よって `%` を含む title は素通しでよく、避けるべきなのは
  ///   nonce 側にリテラル `%` を入れることだけ。
  static func markerTemplate(nonce: String) -> String {
    "\(nonce) " + TmuxListPanes.agentPaneStatusFormat
  }

  /// マーカーは capture の**後**に置く。実測した事実は「列は失敗した地点で止まり、そこまでの
  /// stdout だけが残る」「stdout は引数の順に並ぶ」の2つ (tmux 3.4)。ここから、マーカーを前に
  /// 置くと最後の pane の画面が完全かどうかを stdout から判定できず、途中で切れた画面を
  /// 完全な画面として配ってしまう。後に置けば、マーカーが届いた pane だけが完全だと分かり、
  /// 失敗した pane は**最後に完成した pane の次**に決まる。
  static func arguments(panes: [PaneID], nonce: String) -> [String] {
    let marker = markerTemplate(nonce: nonce)
    var arguments: [String] = []
    for pane in panes {
      if !arguments.isEmpty { arguments.append(";") }
      arguments.append(contentsOf: ["capture-pane", "-e", "-p", "-t", pane.rawValue])
      arguments.append(";")
      arguments.append(contentsOf: ["display-message", "-t", pane.rawValue, "-p", marker])
    }
    return arguments
  }

  /// バッチごとに作り直す。画面には過去のバッチのマーカーが残り得るため、固定文字列だと
  /// capture の中身をマーカーと読み違える。`display-message -p` はテンプレートを strftime
  /// 展開する (tmux 3.4 実測: `MARKER-%0-end` → `MARKER--end`) ので、`%` を含めない。
  static func makeNonce() -> String {
    "AWT" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  /// `expected` の先頭から、マーカーで閉じられた pane を順に返す。閉じられていない末尾
  /// (= 列が失敗した地点、またはマーカーが壊れた地点) は含めない。
  ///
  /// 各 pane の画面は、単独で `capture-pane -e -p -t <pane>` を撃った stdout と
  /// バイト一致する (tmux 3.4 で実測)。`capture-pane -p` の stdout は必ず改行で終わるため、
  /// 行を再結合したあとに改行を1つ足して復元する。
  ///
  /// - Important: 行志向で走査してよいのは、`pane_title` に生 LF を入れられないため
  ///   (tmux 3.4 実測: `select-pane -T` に LF を含む文字列を渡すと exit 0 のまま title が
  ///   更新されず、OSC 2 で LF を送ると LF だけが落ちて `oscsecond` になった。生 0x1F も同じく
  ///   落ちた)。将来の版で入り得るようになっても、区切りが増えて `parseAgentPaneStatus` が
  ///   field count で失敗するため、壊れた title を配らず「その pane が取れなかった」側へ倒れる。
  static func parse(stdout: String, nonce: String, expected: [PaneID]) -> [Entry] {
    let markerPrefix = nonce + " "
    var entries: [Entry] = []
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
      // マーカーが壊れていても列が止まらない経路がある。tmux 3.4 の `display-message` は
      // 存在しない pane を指しても **exit 0** で空の `#{pane_id}` を返す (実測)。
      // よって exit code ではなく「期待どおりのマーカーが届いたか」を完成の条件にする。
      guard nextIndex < expected.count,
        let status = try? TmuxListPanes.parseAgentPaneStatus(
          output: String(line.dropFirst(markerPrefix.count))),
        status.paneID == expected[nextIndex]
      else {
        return entries
      }
      entries.append(
        Entry(
          pane: status.paneID,
          screen: pending.isEmpty ? "" : pending.joined(separator: "\n") + "\n",
          title: status.title))
      pending.removeAll(keepingCapacity: true)
      nextIndex += 1
    }
    return entries
  }
}
