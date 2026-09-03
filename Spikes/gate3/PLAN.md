# Gate 3 PoC スパイク計画 — Agent Adapter

- 作成日: 2026-09-03
- ブランチ: `spike/issue-18-gate3-plan`
- 対象: `docs/architecture.md` §24 「Gate 3: Agent Adapter」
- 対応 Issue: #18 (本計画) → #19 (実施) → #20 (`/decide`) → #21 (本実装)
- ステータス: **調査と計画のみ**。スパイク実施は未着手。

---

## 0. この文書の位置付け

本文書は Gate 3 スパイクに着手するための**調査結果と作業計画**であり、設計判断ではない。

- `docs/architecture.md` の状態区分(確定／現在の推奨／未確定／対象外)を**変更しない**。§12.4 は未確定のままであり、本文書はどの項目も昇格しない。
- スパイクコードは**スパイク品質**とし、`Spikes/gate3/` 配下に隔離する。本体コードへは持ち込まない(`.swiftlint.yml` / `.github/workflows/ci.yml` で `Spikes/` は既に対象外)。得るのは知見であり、コードではない。
- 本 Gate は「どの信号がどの状態をどれだけ正確に取れるか」を**実測する**ところまでを担う。
  - `AgentAdapter` の **API 形状の確定は行わない**(#20 で `/decide`)。
  - **本実装も行わない**(#21)。
- 調査で判明した代替案は「選択肢として記録する」に留める。**採用判断はユーザーが行う。**

---

## 1. 目的

Claude Code と Codex について、設計書 §12 の共通状態 7 種を**どこまで正確に取得できるか**を実測し、
`AgentAdapter` の本実装(#21)に進んでよい材料を出す。

Gate 3 が他とは異なる点: Gate 1 が「不成立なら作り直し」だったのに対し、Gate 3 は**不成立でも製品は成立する**。
取得できない状態は `Unknown` として明示する方針が §12.3 と §24「PoC後の判断」で既に確定しているため、
本 Gate の産物は可否の二値ではなく、**「どこまで縮退するか」の境界線**である。

したがって本スパイクが最優先で答えるべき問いは次の 2 つ。

1. **無設定(ユーザーが何も仕込まない)状態で、どの状態まで取れるか。**
2. **取れない状態を、静かに間違えず `Unknown` へ落とせるか。** — 誤って `Working` / `Idle` に丸めるのが最悪の失敗である(§12.3)。

---

## 2. §24 Gate 3 チェックリスト(設計書からの転記)

> Claude CodeとCodexについて、共通状態をどこまで正確に取得できるか検証する。
>
> 確認事項:
>
> - Working
> - Question
> - Permission
> - Completed／Ready for Review
> - Error
> - Idle
> - Unknown
> - pane／processとの安定した紐付け
> - version update耐性
> - fallback時の誤判定

関連する確定事項:

- §12.1 Adapter 境界: Agent 固有の hook / API / process / 状態情報を Terminal 共通状態へ正規化する。未対応 Agent は process 検出へ fallback する。
  **Agent Skill 側から Terminal API への状態 push を必須にはしない。**
- §12.2 代表状態: pane 単位では詳細状態、worktree には代表状態を 1 つ。優先順位 `Needs Attention > Ready for Review > Working > Idle`。
- §12.3 `Unknown`: process の存在は確認できるが状態を確定できない場合、推測で丸めず `Unknown` とする。Adapter 名・最終成功時刻・エラー詳細を提示できること。
  **Agent そのものの失敗と Adapter の状態取得失敗を混同しない。**
- §4 tmux モデル: 1タスク = 1 worktree = 1タブ = 1 専用 tmux session。tmux を再実装しない。
- §5 Agent Terminal が常に主 UI。
- §23 ライセンス方針: permissive のみ。他プロジェクトのコードを「参考に」コピーしない。

既存実装との接続(本 Gate の入力):

- `TerminalCore/AgentState.swift` — 7 状態と `WorktreeStateCategory` は実装済み。本 Gate はこの語彙を**増やさない**。
- `TerminalCore/AgentAdapter.swift` — protocol は宣言のみ。`observeState` が `throws` ではなく `.unknown` を返す形も**暫定**であり、本 Gate の結果を受けて #20 で見直す。
- `Adapters/TmuxListPanes.swift` — `PaneSnapshot`(`pane_id` / `pane_pid` / `pane_tty` / `pane_current_command` / `pane_current_path` / `pane_title` / 終了情報)は取得済み。信号 S1 / S5 の土台として再利用する。

---

## 3. 環境調査結果(2026-09-03 時点、実機で確認)

| 項目 | 実測値 | 備考 |
|---|---|---|
| macOS | 26.5.2 (build 25F84) | Gate 1 と同一機 |
| tmux | 3.4 | サポート下限として確定済み(#85 / 設計書 §4)。**版差検証はこの下限を含めて行う** |
| Claude Code | 2.1.259 | `~/.local/share/claude/versions/` 配下。`CLAUDE_CONFIG_DIR=~/.claude-own` |
| Codex CLI | 0.152.1 | `codex exec` / TUI とも同一バイナリ |
| tmux format の可用性 | `window_activity` / `window_bell_flag` / `window_activity_flag` / `pane_dead` / `pane_in_mode` / `pane_pipe` は 3.4 で解決される。`window_silence` は空文字列を返した | 隔離 server (`tmux -L`) で確認。空を「取得失敗」と解釈しないこと |

**Agent 側の hook 機構(本調査で判明した最重要事項)**

Claude Code と Codex は**どちらも hook 機構を持ち、イベント語彙がほぼ一致している**。
Gate 3 の設計を「Claude Code だけが hook を持つ」前提で組む必要はない。

| イベント | Claude Code 2.1.259 | Codex 0.152.1 |
|---|---|---|
| セッション開始 / 終了 | `SessionStart` / `SessionEnd` | `session_start` / `session_end` |
| ユーザー入力 | `UserPromptSubmit` | `user_prompt_submit` |
| ツール実行前 / 後 | `PreToolUse` / `PostToolUse` | `pre_tool_use` / `post_tool_use` |
| 権限要求 | `PermissionRequest` | `permission_request` |
| ターン終了 | `Stop` | `stop` / `notify` の `turn-ended` |
| subagent | `SubagentStart` / `SubagentStop` | `subagent_start` / `subagent_stop` |
| compact | `PreCompact` / `PostCompact` | `compact` (pre/post) |
| 中断 | — | `interrupt` |
| 通知 | `Notification` | `notify` プログラム(`notification_method` / `notification_condition` 設定) |

- 出典: 各 CLI バイナリ内の文字列と `codex --help`。**公開ドキュメントでの裏取りと、実際に発火させての確認は M1 で行う**(バイナリ内文字列の存在は「その版で有効」の証明にならない)。
- Codex 側は hook に **trust 機構**がある(`--dangerously-bypass-hook-trust` の存在から。設定は `hooks.json` / `hooks.managed_dir`)。無人での有効化可否は M1 の確認事項。

**Agent 側の transcript**

| Agent | 位置 | 現況 |
|---|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR/projects/<cwd スラッグ>/<session-uuid>.jsonl` | 追記型。実在を確認 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` | 追記型。**2026-09-03 のファイルが存在し、現役**。並行して `thread_history_1.sqlite` も更新されている(二重管理。どちらが正かは M1 で確認) |

いずれも**非公開フォーマット**であり、版数更新耐性は低いと見込む(§7 の撤退基準に反映)。

---

## 4. 信号候補の棚卸し

Issue #18 が求める「信号候補の列挙」。各候補に **Tier**(ユーザー設定を要するか)を付す。
Tier は §12.1 の「Agent Skill からの状態 push を必須にしない」および CLAUDE.md「Agent Skills が無くても素の端末 + worktree 管理として動く」制約に直結する。

- **Tier A** — 無設定で取れる。Agent 側に何も仕込まない。**これが製品の下限を決める。**
- **Tier B** — ユーザーが設定を入れれば取れる。オプトイン機能の上限を決める。
- **Tier C** — 設定は不要だが、Agent の内部生成物に依存する。版数更新で壊れる前提で扱う。

### 4.1 S1: プロセス観測 (Tier A)

`PaneSnapshot`(`pane_pid` / `pane_current_command` / `pane_tty`)+ `ps` によるプロセスツリー観測。

| 観測項目 | 何が取れそうか | 検証すべき点 |
|---|---|---|
| `#{pane_current_command}` | pane の前景プロセス名 | `claude` / `codex` と出るか、`node` 等になるか。ラッパー(mise / asdf / npx)経由でどう変わるか |
| `pane_pid` からの子孫探索 | Agent プロセスの特定 | shell の子として起動するため 1 段では足りない。何段まで辿るか |
| 子プロセスの有無 | **ツール実行中 = Working の強い証拠** | ただしツールを実行しない思考中は子が居ない。Working の一部しか覆えない |
| CPU 使用率 / プロセス状態 (`ps -o state,pcpu`) | Working / Idle の弁別 | **API 応答待ちも入力待ちも sleep である**。弁別できるという仮説は疑わしい。実測で否定される前提で測る |
| プロセス不在 | Agent が居ない | これは `Unknown` ではない(§12.3: `unknown` は「プロセスは居るが状態不明」)。混同しないこと |

fallback (`UnsupportedAgentFallback`) はこの信号だけで構成される。**fallback で `Working` と `Idle` を区別できる範囲**は §12.4 の未確定事項そのものであり、M3 の主要な測定対象。

### 4.2 S2: pane 内容キャプチャ (Tier A)

`tmux capture-pane -p [-e] [-a] [-N]` による画面テキストの解析。

- 両 Agent とも TUI であり、状態は画面に出ている(「esc to interrupt」相当のスピナー、権限ダイアログ、質問プロンプト、エラーバナー、入力待ちの枠)。
- **alternate screen の扱いに注意**: `capture-pane` は現在の画面を取り、`-a` は「代替画面」を指す。Codex は既定で alternate screen を使う(`--no-alt-screen` で無効化できる)。どちらのフラグで何が取れるかを M1 で確定させる。
- 最大の弱点は**偶発的な信号**であること。文言・配色・幅・ロケール・テーマ・版数のどれが変わっても壊れる。
  - よって S2 は「使えるか」ではなく「**どれだけ速く壊れるか**」を測る対象とする(§6 の版数耐性、§7-6)。
- 実装上の制約(既知): 幅が狭いと文言が折り返される。日本語幅は tmux 3.4 で ZWJ が壊れる(Gate 1 申し送り)。**マッチングを行末・固定幅前提で書かない**。

### 4.3 S3: Agent hooks (Tier B)

§3 の表の hook を使い、Agent 側から状態イベントを外部ファイル(JSON Lines)へ書き出させる。

- 状態への写像(**仮説。M2 で検証する**):

  | hook イベント | 想定する共通状態 |
  |---|---|
  | `UserPromptSubmit` / `user_prompt_submit` | `Working` へ遷移 |
  | `PreToolUse` / `pre_tool_use` | `Working` 継続 |
  | `PermissionRequest` / `permission_request` | `Permission` |
  | `Stop` / `stop` / `turn-ended` | `Completed` |
  | `SessionEnd` / `session_end` | Agent 終了(状態ではなく消滅) |
  | `Notification` (Claude) | `Question` または `Permission`。**payload を見ないと分けられない** |

- `Question` の検出は Agent 固有色が最も強い。Claude Code では質問用ツールの `PreToolUse` として現れる可能性があるが、**そのツール名は Claude Code 固有知識であり `ClaudeCodeAdapter` の内側から出してはならない**(§12.1、CLAUDE.md「Claude-Code-only feature を作らない」)。M2 で「Codex 側に対応する信号があるか」を必ず確認し、無ければ **Codex では `Question` を取れないと記録する**(推測で埋めない)。
- リスク:
  - ユーザーが既に自分の hook を設定している場合の共存(設定ファイルを本アプリが書き換えてよいか)。**これは設計判断であり、本 Gate では判断しない。可否と衝突の実態だけ記録する。**
  - Codex の hook trust。無人で有効化できないなら Tier B の実用性が落ちる。
  - hook プロセスの起動コストが Agent の応答を遅らせないこと。

### 4.4 S4: transcript / rollout JSONL (Tier C)

§3 の transcript を tail して状態を読む。

- 設定不要で、hook より情報量が多い(ツール名、エラー内容、ターン境界)。
- 弱点が 2 つ。
  1. **pane との紐付けが自明でない。** cwd スラッグ + mtime + PID から推定することになり、同一 worktree で 2 つの Agent pane を開くと曖昧になる(§4 のモデル上、実際に起こりうる)。
  2. **非公開フォーマット**。Codex は rollout JSONL と `thread_history_1.sqlite` を並行して持っており、正本が移る可能性がある。
- したがって S4 は「S1 / S2 で足りない分の補強」としてのみ評価し、**これ単独に依存する設計は最初から候補にしない**。

### 4.5 S5: tmux 側の付随信号 (Tier A)

| format / 機能 | 想定用途 | 検証点 |
|---|---|---|
| `#{window_activity}` | 最終出力時刻 → `Working` / `Idle` の代理指標 | 出力が止まる = 思考中でもありうる。単独では不十分 |
| `#{window_bell_flag}` / bell | Agent が入力待ちでベルを鳴らすなら `Needs Attention` の強い信号 | 両 Agent がベルを鳴らすか、設定依存かを実測 |
| `#{pane_title}` (OSC 0/2) | Agent がタイトルに状態を書くなら最良の Tier A 信号 | **書くという確証はない。M1 で実測する** |
| `#{pane_dead}` + 終了ステータス | Agent プロセスの異常終了 → `Error` | 既に `PaneSnapshot.termination` として実装済み |
| `pipe-pane` | ポーリングではなく出力ストリームの購読 | ポーリング間隔問題(#20 の polling/event)への代替案。副作用と負荷を測る |

### 4.6 信号 × 状態 のカバレッジ仮説

M3 の結果でこの表を**実測値に置き換える**。現時点はすべて仮説であり、根拠として引用してはならない。

| 状態 | S1 プロセス | S2 画面 | S3 hooks | S4 transcript | S5 tmux |
|---|---|---|---|---|---|
| `Working` | △ ツール実行中のみ | ○ | ◎ | ○ | △ |
| `Question` | × | △ | ○ (Claude) / ? (Codex) | ○ | × |
| `Permission` | × | ○ | ◎ | ○ | △ (bell?) |
| `Completed` | × | △ | ◎ | ○ | △ |
| `Error` | △ 異常終了のみ | △ | △ | ○ | ○ (dead) |
| `Idle` | △ | ○ | △ (不在の推定) | △ | △ |
| `Unknown` | — | — | — | — | — |

`Unknown` は検出する状態ではなく、**他が確定しなかったときの帰結**である。よって測るのは「`Unknown` を出せたか」ではなく「**`Unknown` にすべき場面で他の状態を出してしまった率**」。

### 4.7 本 Gate では扱わない候補

- **Agent Skill から Terminal API への状態 push を必須にする構成** — §12.1 で「必須にしない」が確定済み。オプションとしての是非も本 Gate の範囲外。
- **`claude -p` / `codex exec` の構造化出力 (`--output-format stream-json` 等)** — 非対話実行の機構であり、Agent Terminal は対話 TUI が主 UI(§5 確定)。観測対象が違う。
- **画面の画像認識 / OCR** — 過剰。S2 のテキストで足りない場面を救えない。
- **`ptrace` / `DYLD_INSERT_LIBRARIES` 等のプロセス内部への侵襲** — 署名・権限・保守性のいずれも割に合わない。
- **他ターミナル製品の状態検出実装のコード流用** — §23 により不可。挙動の観測は自前で行う。

---

## 5. マイルストーン分割

各マイルストーンは「何が分かったら次へ行くか」で切る。実施記録は `Spikes/gate3/README.md` に追記していく(Gate 1 と同じ形)。

### M0. 準備

- 隔離 tmux server (`tmux -L gate3-spike`) 上でシナリオを回すハーネスを作る。**ユーザーの実 tmux server を汚さない**(既存の統合テストと同じ方針)。
- 版数の記録(tmux / Claude Code / Codex / macOS)。以降の全計測にこの版数を刻む。
- ground truth ログの器を作る(§6.1)。
- 使い捨ての作業用リポジトリを `Spikes/gate3/fixtures/` 相当に用意し、Agent に触らせる対象を隔離する。**本リポジトリを Agent の作業対象にしない。**

**完了判定**: 空シナリオを 1 本流し、pane が立ち上がり、ログが 1 行出る。

### M1. 信号の実在確認

§4 の S1〜S5 が **実際に取れるか**を、両 Agent について 1 回ずつ確認する。
数を取るのは M3。ここでは「無い信号」を早期に落とす。

- `pane_current_command` が何になるか(ラッパー経由も含む)
- `pane_title` に Agent が何を書くか(何も書かないなら S5 の主力を落とす)
- ベルが鳴るか
- hook が実際に発火するか(バイナリ内文字列と実挙動の突き合わせ)。Codex の hook trust を無人で通せるか
- transcript JSONL が pane と対応付けられるか。Codex の正本は JSONL か sqlite か
- `capture-pane` の `-a` / `-e` / `-N` の組み合わせで何が取れるか(とくに Codex の alternate screen)

**完了判定**: §4.6 の表の「取れる／取れない」が確定し、M3 で測る信号が絞られている。

### M2. 7状態シナリオの確立

7 状態それぞれについて、**再現可能な作り方**を確立する。Issue #19 の完了条件はここに乗る。

| 状態 | 誘発の方針 | 難所 |
|---|---|---|
| `Working` | 十分に長いタスクを投げる | 「思考中」と「ツール実行中」は別物。**両方を別シナリオとして持つ** |
| `Question` | Agent が利用者に問い返す状況を作る | 決定的に起こしにくい。**起こせないなら「シナリオを作れなかった」と記録する。作れたことにしない** |
| `Permission` | 承認が要る操作(サンドボックス外への書き込み等)を依頼する。Codex は `-a on-request` | 承認ポリシー設定に依存する。設定値も記録する |
| `Completed` | 短いタスクを完了させる | `Idle` との境界が曖昧。**「完了直後」と「完了して放置」を区別して測る**(前者が `Ready for Review`、後者も同じでよいのかは #20 の論点) |
| `Error` | 存在しないモデル指定などで起動時に失敗させる / ターン中に失敗させる | **Agent の失敗と Adapter の失敗を混同しない**(§12.3)。両方のシナリオを別に用意する |
| `Idle` | 起動して何も投げない | 起動直後の初期化中を `Idle` と誤らないか |
| `Unknown` | 信号を意図的に奪う(hook 未設定 + 画面が想定外 + 版数不一致など) | **本 Gate の中核。** ここで他の状態を返したら設計違反 |

**完了判定**: 各状態について「作れた／作れなかった」が両 Agent 分揃い、作れたものは手順がスクリプト化されている。

### M3. 検出可否と誤判定率の実測

M2 のシナリオを、M1 で残った信号ごとに N 回反復し、混同行列を出す(§6)。

**完了判定**: 状態 × Agent × 信号の混同行列と検出遅延が `Spikes/gate3/README.md` に載っている。取れない状態が `Unknown` として明示されている。

### M4. 頑健性

§24 の残り 3 項目。

- **pane / process との安定した紐付け**: detach / reattach、split、pane の respawn、Agent の再起動、PID 再利用を跨いで同一 Agent を同一と識別し続けられるか。
- **version update 耐性**: Claude Code / Codex を 1 版上げ下げして、M3 の混同行列がどう崩れるか。**S2 と S4 は崩れる前提で、崩れ方(静かに誤るか、検出不能になるか)を見る。**
- **fallback 時の誤判定**: 未知 Agent(例: 別の CLI や素の shell)を pane で動かし、`UnsupportedAgentFallback` が何を返すか。**Agent でないものを Agent と誤認しないこと**も測る。

**完了判定**: 3 項目それぞれについて実測結果と、崩れたときの縮退先が記録されている。

### 総括

Gate 1 と同様、**「Gate 3 成立／不成立」の最終判断はユーザーが行う**。スパイクは §7 の撤退基準への当てはめまでを行う。

---

## 6. 計測方法

Issue #19 の完了条件「**誤判定率を実測記録**」を満たすための定義。ここを曖昧にしたまま測ると数字が意味を持たない。

### 6.1 ground truth の取り方

**hook を ground truth に使わない。** hook は S3 として被験信号であり、それを正解に使うと循環する。

正解は次の 2 つで構成する。

1. **シナリオスクリプトが持つ独立したタイムライン** — キー入力を送った時刻、投げたプロンプト、期待する遷移。スクリプト側が知っている事実であり、Agent の出力に依存しない。
2. **事後レビュー用の連続キャプチャ** — 計測中の `capture-pane` を一定間隔で保存し、区間の正解ラベルを人が確認できるようにする。**S2 の判定器とは別経路で保存する**(判定器が取りこぼした画面も残す)。

区間の境界が人の目でも決められない場合は、その区間を「**判定不能**」として集計から外し、外した割合を報告する。曖昧な区間を都合よく正解側へ寄せない。

### 6.2 指標

状態 × Agent × 信号ごとに:

- **検出率 (recall)** — 正解が状態 X の区間で、X を出せた割合
- **誤検出率 (precision の裏)** — X を出した区間のうち、正解が X でなかった割合
- **`Unknown` 落ち率** — 正解が X の区間で `Unknown` を返した割合。**§12.3 の方針上これは失敗ではない。**危険な誤判定と必ず分けて集計する
- **危険な誤判定率** — 正解が `Question` / `Permission` / `Error`(= `Needs Attention`)なのに `Working` / `Idle` / `Completed` を返した割合。**これが Gate 3 の合否を決める数字**
- **検出遅延** — 状態が実際に変わってから判定が変わるまで。p50 / p95
- **代表状態の誤り** — pane 単位ではなく §12.2 の worktree 代表状態として見たときの誤り

### 6.3 サンプリング

- ポーリング間隔は **250ms / 1s / 2s** の 3 条件で測る。間隔を変えたときの検出遅延と CPU / tmux server 負荷を併記する。
  - これは #20 の「polling / event の扱い」に直接の材料を渡すためであり、**本 Gate では方式を決めない**。
- 反復回数 N は状態ごとに **10 回以上**を目安とする。10 回に満たない状態(再現性が低い `Question` 等)は、**回数不足であることを明記して報告する**。少ないサンプルから率を計算して見せない。

---

## 7. 撤退基準(Gate 3 不成立と判断する条件)

§24「PoC後の判断」は「Gate 3 で取得できない状態は推測で埋めず `Unknown` として明示する」としており、
**Gate 3 の不成立は製品全体の作り直しを意味しない**。よって「致命」は製品の前提が崩れるものだけに限る。

### 致命(即不成立 = §12 の状態モデル自体の見直しが要る)

1. **どの信号でも `Working` と `Idle` を区別できない**(両 Agent とも)。タブの代表状態表示(§12.2)が成立せず、「複数 Agent を並列に走らせて状況を一覧する」という製品の中心価値が消える。
2. **pane と Agent プロセスの紐付けが安定しない**。誰の状態を見ているか分からないなら、どの信号も意味を持たない。
3. **危険な誤判定(§6.2)を構造的に避けられない** — `Unknown` へ落とす経路が作れず、`Needs Attention` を静かに `Working` / `Idle` へ丸める実装しか組めない。§12.3 の確定事項に反する。
4. **状態観測が Claude Code でしか成立せず、Codex では原理的に何も取れない**。§12.1 の agent-agnostic 前提が崩れる。

### 重大(条件付き。回避策とコストを添えて報告)

5. **Tier A(無設定)では `Working` / `Idle` / `Unknown` の 3 値しか取れない** — `Needs Attention` 系がユーザーの hook 設定に依存する。製品としては成立するが、通知機能の位置付け(§11.2 の通知設計、§12.3)を段階提供へ変更する判断が要る。
6. **S2(画面キャプチャ)への依存が不可避で、版数更新で静かに壊れる**(M4)。追随コストが継続的に高い。
7. **必要なポーリング間隔でのコストが高すぎる** — 常時 N 個の worktree を監視して CPU / tmux server が実用に耐えない。
8. **hook の導入がユーザー環境と衝突する**(既存設定の書き換えが不可避、Codex の trust を無人で通せない等)。Tier B が実質使えない。
9. **`Error` について、Agent 自身の失敗と Adapter の観測失敗を分離できない**(§12.3 が要求する区別が実装できない)。

### 不成立時の代替候補(**列挙のみ。採用判断はユーザー**)

- **状態語彙の縮退** — worktree 代表状態を `Working` / `Idle` / `Unknown` の 3 値に落とし、`Needs Attention` は hook を入れたユーザーだけのオプトイン機能にする。
- **`pipe-pane` によるストリーム観測**(§4.5)— ポーリング負荷が問題(7)になった場合の代替。
- **hook 設定の導入をユーザーの明示操作にする** — アプリが設定ファイルを書き換えるのではなく、貼り付ける設定断片を提示するに留める。衝突(8)の回避策。
- **Agent Skill 側から状態を書き出す構成の再検討** — §12.1 の「必須にしない」と矛盾しない範囲でのオプション化。**密結合を避ける確定方針に触れるため、ユーザー判断が要る。**

---

## 8. リスクと不明点

| # | 内容 | 影響 | 現時点の扱い |
|---|---|---|---|
| R1 | `Question` を決定的に再現できない可能性が高い | #19 の完了条件「7状態それぞれの検出可否」を満たせない | **「シナリオを作れなかった」も正当な実測結果として報告する。**作れたことにして数字を出さない |
| R2 | hook のイベント一覧をバイナリ内文字列から得ている | 実際には無効・未公開のイベントを前提に組む恐れ | M1 で発火を実測するまで、§3 の表を根拠として引用しない |
| R3 | Agent の版数が計測中に自動更新される(両 Agent とも自動更新機構を持つ) | 混同行列の版数が揃わず、M3 と M4 の切り分けが崩れる | M0 で版数を固定し、自動更新を止める手段を確認する。止められないなら各計測に版数を刻む |
| R4 | Codex の transcript 正本が JSONL から sqlite へ移行中に見える | S4 の前提が測定中に変わる | M1 で正本を確認。**移行中であること自体を S4 の版数耐性の証拠として記録する** |
| R5 | Agent を実際に走らせるため、API 利用料と時間がかかる | M3 の反復回数が確保できない | シナリオは**最小のタスク**で状態を起こす設計にする。長考させない |
| R6 | Agent に実ファイルを触らせるため、事故でリポジトリを壊す | 作業消失 | M0 の隔離作業ディレクトリを必須の前提とする。本リポジトリを対象にしない |
| R7 | tmux 3.4(下限)と最新版で `capture-pane` の挙動が違う可能性 | S2 の結論が環境依存になる | 下限 3.4 を主計測とし、最新版で差分だけ確認する |
| R8 | 誤判定率の分母(区間の切り方)次第で数字が動く | 結論が恣意的になる | §6.1 の「判定不能区間は集計から外し、外した割合を報告する」を厳守 |
| R9 | 本 Gate の結果が `AgentAdapter` protocol の現在形と食い違う | #21 の実装前に protocol を直す必要が出る | **想定内。**`AgentAdapter.swift` は暫定と明記済み。#20 で見直す |

---

## 9. 参照

- `docs/architecture.md` §12(Agent Adapter と状態モデル)、§24(PoC優先項目)、§25(未確定事項)
- `docs/coding-guidelines.md` §5.2(外部 CLI との付き合い方)、§6(Gate 1 申し送り)
- `Spikes/gate1/PLAN.md` / `Spikes/gate1/README.md` — 本計画の書式と、tmux / pane 観測の実測値の出典
- `AgentWorkflowTerminal/Sources/TerminalCore/AgentAdapter.swift` / `AgentState.swift` — 本 Gate の入力となる既存の状態語彙
- Issue #19(実施) / #20(API 形状の確定) / #21(本実装)
