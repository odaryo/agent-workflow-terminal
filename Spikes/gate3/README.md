# Gate 3 スパイク — M0 / M1 / M2 / M3 / M4 実施記録

- 実施日: 2026-09-03
- ブランチ: `spike/issue-19-gate3-run`
- 対象: `PLAN.md` の M0〜M4 / 設計書 §24「Gate 3: Agent Adapter」
- 状態: **M0〜M4 実施済み。** 未実施項目は §9 に明記した。

> この文書は「やってみて何が分かったか」の記録である。
> `docs/architecture.md` の状態区分(確定／現在の推奨／未確定／対象外)は一切変更していない。
> §12.4 は未確定のままであり、`AgentAdapter` の API 形状の確定は #20、実装は #21 で行う。

---

## 0. 一行での結論

**両 Agent とも、ユーザーに何も設定させない範囲 (Tier A) で `Working` / `Permission` / `Completed` / `Idle` を
実用的な精度で取得できた。危険な誤判定 (Needs Attention を `Working` / `Idle` へ丸める) は組み合わせ方次第で
0 にできるが、単独信号ではどれか一つが必ず 100% 危険側に倒れる。**
`Question` は Claude Code でのみ取得でき、Codex には対応する状態が存在しない。
`Error` のうち「ターン中の API エラー」は本スパイクでは再現できず、**未計測のまま残した**。

---

## 1. 環境と版数

`evidence/versions.tsv` に記録。すべての計測はこの版数で行った。

| 項目 | 値 |
|---|---|
| macOS | 26.5.2 (25F84) / arm64 |
| tmux | 3.4 (サポート下限。設計書 §4) |
| Claude Code | 2.1.259 |
| Codex CLI | 0.152.1 |

計測条件: 隔離 tmux server (`tmux -L gate3-spike`)、pane サイズ **140x45 固定**、サンプリング **250ms**、
Agent の作業ディレクトリは本リポジトリ外の使い捨て git リポジトリ。

**ユーザーの実環境設定をそのまま使った。** MCP サーバや `~/.codex/config.toml` の既定が
観測結果に効くことが分かったため(§4.1、§5)、これは意図した条件である。

---

## 2. 手法

### 2.1 record once, classify many

`scripts/recorder.py` が pane の**生信号だけ**を 250ms 間隔で JSON Lines へ落とす
(tmux format 14 種 + `pane_pid` 配下のプロセスツリー + 画面全体のテキスト)。
判定は一切しない。分類器 (`scripts/analyze.py`) は記録を後から読む。
おかげで**シナリオを流し直さずに分類方式を差し替えて再採点できた** — 実際、
S2 の画面パターンは初回の結果を見てから作り直している。

### 2.2 ground truth と、その偏り

`PLAN.md` §6.1 の通り、正解は「script が知っている事実」(いつプロンプトを送ったか) と
「事後レビューで人が確認した画面境界」で作った。**hook は被験信号 S3 なので正解には使っていない。**

境界の出どころが Agent ごとに違い、**これは結果の読み方に効く**。

| Agent | ターン境界の出どころ | 結果への影響 |
|---|---|---|
| Claude Code | 画面テキスト(完了マーカーの**出現回数が増えた**最初のフレーム。直前ターンのマーカーが画面に残り続けるため有無では取れない) | **S2-screen の claude 側は楽観側へ振れる** |
| Codex | `pane_title`(spinner / `Action Required`)。画面には実行中を示す印が出ないため画面からは切れない | **S5-title の codex 側は測定値ではなく正解の定義そのもの。成績として読んではならない** |

境界の前後 **1.0 秒**は判定不能として集計から除外した。除外率は全体の 6.2%(598 / 9693 フレーム)。

### 2.3 分類器

| 名前 | Tier | 中身 |
|---|---|---|
| `S1-proc-naive` | A | 子プロセスが居れば `Working`、居なければ `Idle`。**素朴な fallback がやりがちな実装** |
| `S1-proc-honest` | A | プロセス観測だけでは状態を確定できないと認め、常に `Unknown` |
| `S2-screen` | A | `capture-pane` のテキストへ正規表現 |
| `S5-activity` | A | `#{window_activity}` が直近 2 秒以内なら `Working` |
| `S5-title` | A | `#{pane_title}` |
| `S3-hooks` | B | Agent の hook が書き出したイベント列 |
| `TierA-combined` | A | 種別が要る状態は画面から、実行中かはタイトル / 出力の動きから。当たらなければ `Unknown` |

---

## 3. M1: 信号の実在確認

| 信号 | Claude Code 2.1.259 | Codex 0.152.1 |
|---|---|---|
| `pane_current_command` | **`2.1.259`**(実体が `versions/<版数>` というファイル名。`claude` にならない) | `codex` |
| プロセスツリー | `claude` の他に `npx` / `npm exec chrome-devtools-mcp` / `caffeinate` / 定期的な `git` が常駐 | `codex` の他に定期的な `git` |
| `pane_title` | 起動時 `✳ Claude Code` → **最初のターンで `✳ <タスク見出し>` になり、以降のターンでは更新されない** | **`⠋⠙⠹…`(braille spinner) + ディレクトリ名 = 実行中 / `[ ! ] Action Required │ <dir>` = 操作待ち / ディレクトリ名のみ = 待機** |
| `alternate_on` | 1(代替画面を使う) | 0(インライン。`capture-pane -a` は "no alternate screen" を返す) |
| ベル (`window_bell_flag`) | **全計測を通じて 0。鳴らない** | **同じく 0** |
| `window_activity` | ターン中は毎秒更新、停止で凍結 | 同左。**ただし承認ダイアログ表示中も更新され続ける** |
| `pane_in_mode` | copy-mode で 1 | 同左 |
| hook | **project の `.claude/settings.json` から承認プロンプトなしで発火した。** `SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PermissionRequest` / `PostToolUse` / `Stop` / `Notification` を実測 | **`hooks.json` のスキーマを特定できず、発火させられなかった**(§9) |
| transcript | `$CLAUDE_CONFIG_DIR/projects/<cwd スラッグ>/<uuid>.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`(現役。`session_meta` に cwd と session_id を持つ) |

**Codex がタイトルへ状態を書くのは、本スパイクで最も価値のある発見である。**
無設定の Tier A で `Working` と「操作待ち」を直接読める。
一方 **Claude Code のタイトルは状態信号ではない** — 最初のターンで決まる見出しであり、
2 ターン目以降も、完了しても、更新されない。

### 3.1 S1 のノイズ源

`claude` は MCP サーバ (`npx`) を常駐の子プロセスとして持ち、待機中も `caffeinate` や `git` が現れる。
**「子プロセスが居る = 実行中」は成立しない。** これはユーザーの MCP 設定に由来するため、
実環境では常にこの種のノイズがあると考えるべきである。

---

## 4. M2: 7状態シナリオ

| 状態 | Claude Code | Codex | 備考 |
|---|---|---|---|
| `Working` | ✅ 再現 | ✅ 再現 | 「長考(ツールなし)」と「ツール実行中」を別区間として持った |
| `Question` | ✅ 再現 | ❌ **再現できず** | 下記 §4.1 |
| `Permission` | ✅ 再現 | ✅ 再現 | Codex は `-c approvals_reviewer="user"` が要る(下記 §5) |
| `Completed` | ✅ 再現 | ✅ 再現 | 完了直後と放置後を別ラベル(`completed` / `completed-left`)で測った |
| `Error` | △ 一部のみ | △ 一部のみ | 下記 §4.2 |
| `Idle` | ✅ 再現 | ✅ 再現 | 起動後・無入力 |
| `Unknown` | ✅ 再現 | ✅ 再現 | 画面幅 40 桁 / copy-mode / プロセス kill |

### 4.1 `Question`: Codex には対応する状態が無い

Claude Code は `AskUserQuestion` により選択肢付きの質問画面へ入り、そこで停止する。
hook では `PreToolUse` + `PermissionRequest`(いずれも `tool_name = AskUserQuestion`)として届く。

Codex に同じ依頼をすると、**質問を平文で出力してターンを終える**。入力待ちには戻るが、
それは `Completed` と同じ状態であり、区別できる信号が無い。
`codex features list` でも `default_mode_request_user_input` は `under development` / 無効である。

→ **Codex では `Question` を取得できない。推測で埋めない。**

さらに、Claude Code 側で `Question` と `Permission` を分けるには hook payload の `tool_name` を読む必要がある。
これは Claude Code 固有の知識であり、`ClaudeCodeAdapter` の内側から出してはならない(§12.1)。

### 4.2 `Error`: 再現できた範囲とできなかった範囲

- ❌ **不正なモデル名を対話中に指定 (`/model no-such-model-xyz`)** — 両 Agent とも通常の応答として処理し、エラーにならなかった。
- ❌ **起動時の不正モデル (`--model no-such-model-xyz`)** — Claude Code はそのまま起動した(ステータス行にその名前が出るだけ)。
- ✅ **Agent プロセスの死 (SIGKILL)** — pane は死なず、`pane_current_command` が `bash` へ戻り、子プロセスが消える。
  画面には死ぬ直前の描画が残るため、**画面だけを見ている分類器は古い状態を出し続ける**。
- ❌ **ターン中の API エラー / レート制限** — 安全に再現する手段が無く、**未計測**。

→ `Error` は「Agent プロセスが死んだ」ケースしか実測できていない。§9 に残課題として記録する。

---

## 5. Codex の承認が既定では発生しない

初回の計測で Codex が承認を求めずファイルを書いた。原因はユーザーの `~/.codex/config.toml` の
`approvals_reviewer = "auto_review"` で、承認要求が自動レビューへ回されるためだった
(`-s read-only -a on-request` を付けても変わらない)。
`-c approvals_reviewer="user"` を明示して初めて承認ダイアログが出る(有効値は `user` / `auto_review` / `guardian_subagent`)。

**製品への含意**: 「Permission 状態が出ない」のは Adapter の不具合とは限らず、ユーザーの Agent 設定が原因でありうる。
状態が取れないことと、その状態が発生していないことは区別できない。

---

## 6. M3: 検出可否と誤判定率

- 反復数: 各 Agent **5 run**(1 run で `Idle → Working → Completed → Working → Permission → Working → Completed → 放置` を通す複合シナリオ)。
- **`PLAN.md` §6.3 が目安とした 10 回に満たない。率は参考値として読むこと。**
- 採点フレーム数 9,095 / 除外 598。生データは `evidence/runs/`(追跡対象外)、集計は `evidence/report-composite.json`。

指標の定義は `PLAN.md` §6.2。**`unknown` へ落ちるのは失敗ではない**(§12.3)。
危険なのは Needs Attention を `Working` / `Idle` / `Completed` へ丸めることだけである。

### 6.1 Claude Code (n はフレーム数)

| 分類器 | idle | working | permission | completed | completed(放置) |
|---|---|---|---|---|---|
| | n=455 | n=443 | n=770 | n=1835 | n=1045 |
| `S1-proc-naive` | 1.000 | 0.000 | **0.000 / 危険 1.000** | 0.000 | 0.000 |
| `S1-proc-honest` | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 |
| `S2-screen` | 1.000 | **0.059** | 1.000 | 1.000 | 1.000 |
| `S5-activity` | 0.813 | 0.959 | **0.000 / 危険 1.000** | 0.000 | 0.000 |
| `S5-title` | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 |
| `TierA-combined` | 0.813 | 0.959 | 1.000 | 0.966 | 1.000 |
| `S3-hooks` (Tier B) | **1.000** | **1.000** | **1.000** | **1.000** | **1.000** |

### 6.2 Codex

| 分類器 | idle | working | permission | completed | completed(放置) |
|---|---|---|---|---|---|
| | n=455 | n=486 | n=763 | n=1797 | n=1046 |
| `S1-proc-naive` | 0.822 | 0.025 | **0.000 / 危険 1.000** | 0.000 | 0.000 |
| `S1-proc-honest` | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 |
| `S2-screen` | 1.000 | 0.710 | 1.000 | 1.000 | 1.000 |
| `S5-activity` | 0.930 | 1.000 | **0.000 / 危険 1.000** | 0.000 | 0.000 |
| `S5-title` | (正解の定義に使用。成績として読まない) | 〃 | 〃 `attention` 1.000 | 〃 | 〃 |
| `TierA-combined` | 0.930 | 1.000 | 1.000 | 0.994 | 1.000 |
| `S3-hooks` (Tier B) | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 | unknown 1.000 |

### 6.3 読み取れること

1. **単独信号はどれか一つで必ず 100% 危険側へ倒れる。**
   `S5-activity` は承認待ちを、Claude Code では「出力が止まった」ので `Idle`、
   Codex では「ダイアログが再描画され続ける」ので `Working` と判定した。**逆方向の誤りが同じ信号から出る。**
   `S1-proc-naive` は両 Agent とも承認待ちを `Idle` と判定した。
2. **Claude Code の `Working` は画面に出ていない。**
   長い応答を流している間、画面にはスピナーもトークンカウンタも残らず、
   出力されたテキストと入力欄しか無い。`S2-screen` の working 再現率が 0.059 なのはこれが理由で、
   残りは `Idle` と判定された(危険な誤りではないが、実行中を見落とす)。
   **実行中の検出はフレーム間の差分 = `window_activity` に頼るしかない。**
3. **組み合わせれば危険な誤判定は 0 になった。** `TierA-combined` の危険率は全状態で 0.000。
   代償は `Idle` の取りこぼし(0.813 / 0.930 — 定期再描画を `Working` と見る)。
4. **`S3-hooks` は Claude Code で完璧(全状態 1.000)。** ただし Tier B であり、Codex では使えなかった。
5. **`S1` は状態検出には使えないが、生存確認としては必須である。** §7.3 参照。

---

## 7. M4: 頑健性

### 7.1 pane / process の紐付け (`evidence/m4-binding.tsv`)

| 操作 | `pane_id` | `pane_pid` |
|---|---|---|
| split / zoom / unzoom | 不変 | 不変 |
| client の attach / detach | 不変 | 不変 |
| `swap-pane` | 不変 | 不変。ただし **`list-panes` の出力順が入れ替わる** |
| `respawn-pane` | 不変 | **変わる** |
| pane 内の shell 終了 | pane 消滅 | — |

- **`pane_id` を鍵にする限り紐付けは安定する。** 出力順や「先頭の pane」に依存してはならない。
- `pane_current_command` は pane の shell ではなく**前景プロセス**を映す(`sleep` 実行中は `sleep`)。
- `pane_pid` は pane の shell であり Agent 本体ではない。Agent は子孫として辿る必要がある。

### 7.2 version update 耐性

版を上げ下げしての再計測は行っていない(§9)。代わりに**構造的な脆さ**が実測から判明した。

- **`pane_current_command` が Claude Code では `2.1.259` になる。** 実行ファイルが `versions/<版数>` だからで、
  **Agent 更新のたびにこの値が変わる。** 名前で Claude Code を判定する実装は初回の更新で壊れる。
  プロセスツリー側の `comm` は `claude` なので、そちらを見る必要がある。
- `S2-screen` の依存文言(`Do you want to …?`、`· done HH:MM`、`Would you like to`、`1. Yes, proceed`)は
  すべて UI 文言であり、版数・ロケール・テーマで変わりうる。
- `S5-title` の Codex の `[ ! ] Action Required` も UI 文字列である。

### 7.3 画面が読めない状況 (`deprived` シナリオ)

| 状況 | 起きたこと |
|---|---|
| 画面幅 40 桁 | Claude Code: ステータス行が切れてパターンが外れ、42% のフレームが `unknown` へ落ちた(危険な誤りは無し)。Codex: 完了後なのに `Idle` と判定した(**誤りだが危険側ではない**) |
| copy-mode | `capture-pane` が copy-mode 突入時点の画面を返し続け、**判定が固まる**。`pane_in_mode = 1` で検出できるので、ここは `Unknown` へ落とす実装が可能 |
| Agent プロセスを SIGKILL | 全分類器が `unknown` を返した。ただしこれは分類器が**生存確認を先に行っているから**であって、画面は死ぬ直前の描画のまま残っている。生存確認を外すと全分類器が古い状態を出し続ける |

### 7.4 fallback の誤判定

`bash` / `python3 -i` / `top` / `vim` を pane で動かし、79 フレームずつ観測。
**どちらの Adapter も「担当できる」と判定しなかった(0/79)。** 誤検出は無い。
`pane_current_command` は `bash` / `Python` / `top` / `vim` を正しく返す。

### 7.5 観測コスト (`evidence/m4-polling-cost.tsv`)

pane ごとに 1 observer を回し、20 秒あたりの CPU 秒。

| pane 数 | 間隔 | user | sys | 合計 / 20秒 |
|---|---|---|---|---|
| 1 | 250ms | 4.50 | 12.79 | 17.3s (コア 87%) |
| 1 | 1s | 1.28 | 3.51 | 4.8s |
| 1 | 2s | 0.69 | 1.83 | 2.5s |
| 5 | 250ms | 7.15 | 21.16 | 28.3s (コア 142%) |
| 5 | 1s | 2.08 | 6.03 | 8.1s |
| 5 | 2s | 1.04 | 2.95 | 4.0s |

pane 数を 5 倍にしても CPU は 1.6 倍にしかならない。`ps` の 1 回の走査が
pane 数によらず同じコストであることと、5 observer が同時に走ることで
OS 側のキャッシュが効くためと見られるが、**内訳までは切り分けていない**。
記録したサンプル数が 1 pane のケースだけ想定値 (80) と合わず 237 だったため、
**この表は CPU の桁を見る用途に留め、1 サンプルあたりの単価に換算しないこと。**

**この数字は本スパイクのハーネスのコストであって、製品の見積もりではない。**
1 サンプルごとに Python から `tmux` を 2 回起動し、さらにプロセステーブル全体を `ps` で走査している。
実測した 1 回あたりの所要時間は **`ps -Ao` = 46.5ms / `tmux list-panes` = 5.7ms / `tmux capture-pane` = 6.6ms** で、
**支配的なのは `ps` の全走査**である。

→ #20 への材料: 250ms ポーリングは「毎回プロセステーブルを舐める」実装では成立しない。
プロセス観測は生存確認に限って低頻度で回し、状態観測は tmux 側の安価な取得に寄せるべきである。

---

## 8. §24 チェックリストの最終状態

凡例: ✅ 取得できた / ⚠️ 条件付き / ❌ 取得できない / ❓ 未計測

| §24 の項目 | Claude Code | Codex | 根拠 |
|---|---|---|---|
| `Working` | ✅(Tier A 0.959) | ✅(Tier A 1.000) | §6。画面ではなく出力の動き / タイトルから取る |
| `Question` | ✅(hook)/⚠️(画面) | ❌ **存在しない** | §4.1 |
| `Permission` | ✅(Tier A 1.000) | ✅(Tier A 1.000) | §6 |
| `Completed／Ready for Review` | ✅(0.966) | ✅(0.994) | §6。完了直後と放置後で差は出なかった |
| `Error` | ⚠️ プロセス死のみ | ⚠️ プロセス死のみ | §4.2。**ターン中の API エラーは未計測** |
| `Idle` | ⚠️(0.813) | ⚠️(0.930) | §6。定期再描画を `Working` と誤る |
| `Unknown` | ✅ | ✅ | §7.3。危険側へ倒れずに `Unknown` へ落とせる |
| pane／process との安定した紐付け | ✅ | ✅ | §7.1。`pane_id` を鍵にする限り安定 |
| version update 耐性 | ⚠️ 構造的に脆い | ⚠️ 同左 | §7.2。**再計測は未実施** |
| fallback 時の誤判定 | ✅ 0/79 | ✅ 0/79 | §7.4 |

---

## 9. 未実施・未計測(そのまま残す)

1. **ターン中の API エラー / レート制限による `Error`** — 安全に誘発する手段が無く未計測。
2. **Codex の hook (S3)** — `hooks.json` は `--strict-config` を通り、`--dangerously-bypass-hook-trust` の警告も出たが、
   イベントが 1 件も発火しなかった。スキーマ(キー名・入れ子・イベント名)を特定できていない。
   バイナリ内には `pre_tool_use` / `permission_request` / `stop` などの実装ファイル名と、
   `PreToolUse` / `PermissionRequest` などの CamelCase 文字列の**両方**があり、どちらが設定上の名前かも未確定。
3. **S4 (transcript / rollout JSONL) の分類器** — 存在と場所は確認した(§3)が、混同行列は取っていない。
   pane との紐付けが未解決のため。Claude Code のディレクトリ名は cwd を単純置換したスラッグで、
   `_` も `-` になる**非可逆な変換**であり、異なる cwd が衝突しうる。
   同一 cwd に多数の session ファイルが並ぶため、hook 無しで pane と session を結ぶ鍵が無い。
4. **版数を上げ下げしての再計測**(§7.2)。
5. **反復数** — 各 Agent 5 run。`PLAN.md` §6.3 の目安 10 回に届いていない。
6. **検出遅延 (p50 / p95)** — 記録は 250ms 刻みで残っているが、集計していない。
7. **`Question` / `Error` / `Unknown` の混同行列** — シナリオは流したが、
   複合シナリオのように真値区間を機械的に切れないため、定性記録に留めた。

---

## 10. #20 (API 形状の確定) への申し送り

判断はユーザーが行う。以下は材料。

1. **単独信号で状態を決める設計にしない。** 種別(`Permission` / `Question`)は画面か hook、
   実行中かはタイトルか出力の動き、生存はプロセス — と**役割の違う信号を合成する**必要がある(§6.3)。
2. **生存確認と状態観測は頻度が違う。** プロセス走査は高コスト(§7.5)で、状態観測は tmux から安価に取れる。
   `AgentAdapter` が両方を 1 つの `observeState` に押し込むと、頻度を分けられない。
3. **`AgentState` に「注意が要ることは分かるが種別は不明」を置く場所が無い。**
   Codex のタイトルはまさにこれを返す(`[ ! ] Action Required`)。
   現状は `Unknown` へ落とすしかなく、§12.2 の `Needs Attention` へ上げられない。
4. **`Idle` と `Completed` の境目は観測できない。** Claude Code は完了マーカーを画面に残し続け、
   Codex はタイトルを待機状態へ戻す。「完了直後」と「完了して放置」に観測上の差は出なかった(§6)。
   `Ready for Review` をいつ降ろすかは観測ではなくユーザー操作で決めるしかない。
5. **`Unknown` には理由が要る。** 「画面が読めない(copy-mode)」「Agent が居ない」「Adapter が状態を決められない」は
   すべて別物で、UI での扱いも違う(§12.3 が要求する区別)。とくに**「Agent が居ない」は `Unknown` ではない**。
6. **polling か event かは、信号ごとに違う。** hook はイベント、tmux format はポーリング。
   片方に統一する API は片方を歪める。

## 11. #21 (実装) への申し送り

1. **`pane_current_command` で Claude Code を判定しない**(版数文字列になる)。プロセスツリーの `comm` を見る。
2. **`list-panes` の出力順に依存しない**(`swap-pane` で入れ替わる)。鍵は `pane_id`。
3. **生存確認を必ず先に置く。** 死んだ Agent の画面は残り続ける(§7.3)。
4. **`pane_in_mode` を見て、copy-mode 中は画面由来の判定を無効化する。**
5. **画面パターンは行末・固定幅を前提に書かない。** 40 桁でステータス行が切れて外れた(§7.3)。
6. **Codex のタイトルは種別を持たない。** `Action Required` を `Permission` と決めつけない。
7. **hook は Claude Code でのみ実測できている。** Codex にも同じ仕組みがある前提でコードを書かない。
8. **ベルは使えない**(両 Agent とも鳴らさない)。

---

## 12. 再現手順

```shell
Spikes/gate3/scripts/record-versions.sh              # 版数を記録
Spikes/gate3/scripts/setup-hooks.sh                  # S3 用の hook を作業ディレクトリへ置く
Spikes/gate3/scripts/run-suite.sh claude composite 5 # 複合シナリオ 5 回
Spikes/gate3/scripts/driver.sh claude question r1    # 単発シナリオ
Spikes/gate3/scripts/m4-binding.sh                   # pane 紐付け
Spikes/gate3/scripts/fallback-probe.sh               # 非 Agent の誤検出
Spikes/gate3/scripts/m4-polling-cost.sh              # 観測コスト
python3 Spikes/gate3/scripts/analyze.py Spikes/gate3/evidence/runs/*-composite-r*
```

`G3_WORK` で作業ディレクトリを、`G3_SOCKET` で tmux socket を差し替えられる。
Agent を 2 種同時に回す場合は `G3_WORK` を分けること(hook ログと成果物が衝突する)。
