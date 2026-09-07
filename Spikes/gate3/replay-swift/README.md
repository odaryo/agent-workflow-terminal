# replay-swift — 実装済み Adapter による Gate 3 記録の再生

設計書 §12.2「代表状態の表示は安定化する」の**保持時間の具体値**を実測で決めるために書いた
使い捨てハーネス。`scripts/analyze.py` (Python の分類器) と違い、**製品コードの
`ClaudeCodeAdapter` / `CodexAdapter` / `ProcessDetectionFallbackAdapter` をそのまま呼ぶ**。
分類器を書き直すと本物の Adapter と乖離し、そこで出した数字で製品の既定値を決められないため。

## 使い方

```shell
swift run -c release replay-swift                        # 追跡済みの遷移列 TSV から再計算
swift run -c release replay-swift --records ../evidence/runs        # 生記録から計算
swift run -c release replay-swift --records ../evidence/runs --dump # 遷移列 TSV を作り直す
swift run -c release replay-swift --score --records ../evidence/runs --poll 2.0  # 混同行列
```

## `--score` — 真値区間との突き合わせ

`scripts/analyze.py` は Python で書き直した分類器を採点するが、`--score` は**実装済みの
`ClaudeCodeAdapter` をそのまま**記録へ当てて混同行列を出す。対象は真値イベント
(`truth.jsonl`) を持つ `claude-composite-r1`〜`r5`。真値区間は `analyze.py` の
`truth_intervals()` の claude 側の移植 (ターン終了は完了マーカー `·\s*done\s+\d` の
**出現回数が増えた**最初のフレーム。直前ターンのマーカーが画面に残るため有無では切れない)、
境界前後 1.0 秒 (`GUARD`) は集計から外す。生記録が要るため `--records` は必須。

`--poll <秒>` (既定 0.25) は評価するポーリング間隔。記録間隔 0.25 秒の倍数だけを受け付ける
(黙って丸めると、表示された値で再現したつもりが別の間隔になる)。**間引くのは分類結果ではなく
入力**で、`secondsSinceScreenChange` は前回観測との差なので、粗い polling では
「2 秒前の画面と違うか」になる。0.25 以外では位相を 0.25 秒刻みでずらした `poll/0.25` 通りを
合算する (2.0s なら 8 位相)。位相 1 つでは標本が 1/8 になり、位相の当たり外れが数字を支配する。

実測 (2026-09-07、5 run・GUARD 除外後の 4548 フレーム)。危険率は真値が Needs Attention
(`question` / `permission` / `error`) の区間にしか定義が無いので、他の行は `—`:

| 真値 | n | recall (0.25s) | recall (2.0s) | 危険率 (両方) |
| --- | --- | --- | --- | --- |
| working | 443 | 0.867 (取りこぼしは全て `unknown`) | **0.995** (誤判定は `completed` 2 フレーム) | — |
| permission | 770 | 1.000 | 1.000 | 0.000 |
| completed | 1835 | 0.986 | 0.953 | — |
| completed-left | 1045 | 1.000 | 1.000 | — |
| idle | 455 | 0.892 | **0.763** (98 フレームが `working`) | — |

製品の `AgentObservationIntervals.signals` は 2.0 秒側。working の recall が粗い polling で
**上がる**のは、画面鮮度が「前回の観測から画面が変わったか」であり、間隔が広いほど
変化を捉えやすいため。**同じ理由で idle の recall は下がる**。設計書 §12.2 は working 側の
残差 (443 中 2 フレーム) を許容範囲として記録し、idle 側の低下も併記している。

## 生記録と遷移列 TSV

`evidence/runs/` (recorder が落とした 250ms 周期の生信号) は容量のため
`.gitignore` されており、**記録した Mac にしか無い**。そのままでは第三者が実測を検証できないため、
Adapter の分類結果だけを `evidence/replay-observations.tsv` (301行) として追跡している。
保持時間の表はこの TSV だけで再現できる。

TSV は状態が変わったフレームだけを持ち、再生時に 250ms 格子へ展開し直す。
recorder の実際の間隔には揺らぎがあるため、**個々の時刻は最大 1 フレーム (250ms) ずれる**。
設計書 §12.2 が引く数字は生記録から取ったもので、**TSV から再現すると次の3つだけがずれる**。
結論 (どの保持時間で中断が何件残るか、昇格が遅れないか、9 秒と 10 秒の優劣) は変わらない。

| | 生記録 | 追跡 TSV |
| --- | --- | --- |
| 合計時間 | 57.4 分 | 57.3 分 |
| 保持10秒の表示遷移/分 | 1.79 | 1.80 |
| `Working` 起点のみ・保持9秒で5秒未満の `Idle`／`Unknown` | 28 回 | 27 回 |

## 記録側と製品側のモデル差 (実測して合わせたもの)

- **liveness に pane プロセス自身を含める。** recorder の `descendants()` は `children[pid]` から
  辿るため pane_pid 自身を含まないが、製品の `TmuxAgentSignalSource.processTreeNames(of:rows:)` は
  pane_pid 自身から辿る。fallback の 4 run は bash / Python / top / vim を pane プロセスとして
  直接動かしており `procs` が常に空のため、合わせないと `ProcessDetectionFallbackAdapter` へ
  1 フレームも届かない。集計値は変わらない (定数 run なので遷移を生まない) が、
  「3 つの Adapter を当てた」が事実にならない。
- **recorder のエラーフレームを落とす。** `codex-error-startup-r1` の 158 フレームのうち 132 は
  `{"ts":…, "error":"can't find window: …"}` で、Agent の状態ではなく記録側の失敗。
  観測が無かったものとして除く。
- **画面を取れなかったフレームで空文字を入れない。** 実路は capture 失敗時に
  `forget(paneID:)` して `secondsSinceScreenChange` を `nil` にする。空文字を入れると
  「画面が変化した」ことになり、復帰直後のフレームが `working` に化ける。

## 何を測っているか

- **working の中断**: `Working` 表示が `Idle` / `Unknown` に割り込まれて `Working` へ戻るまでの長さ。
  これが §12.2 の言う振動の実体。
- **表示遷移/min**: 保持を当てたあとに実際にタブへ出る遷移の頻度。
- **昇格が保持で変化した回数**: `Needs Attention` / `Ready for Review` の遷移時刻が
  保持なしと変わっていないかの検証。§12.2 の「人の対応が要る通知を遅らせない」を機械的に確かめる。
- **保持の対象範囲の比較**: 「`Working` 起点の降格だけ保持」と「`Idle` / `Unknown` へ入る遷移を
  すべて保持」で、短時間だけ表示される `Idle` / `Unknown` がどれだけ残るか。
