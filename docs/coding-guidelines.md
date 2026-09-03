# コーディング規約

`agent_workflow_terminal` の実装規約です。

## 0. この文書の方針

**薄く始める。** ツールで機械的に決められること (インデント、空白、import 順、命名の綴り) は
書きません。それらは `.swift-format` と `.swiftlint.yml` が担当します。

ここに書くのは**設計判断レベルの規約**、つまり「守らないと後で設計が壊れるもの」だけです。
迷ったときに参照するのは次の順序です。

1. `docs/architecture.md` の**確定**事項 — 最優先。この文書より強い。
2. 本文書。
3. `Spikes/gate1/README.md` の申し送り — 実装上の既知の制約。

規約は必要になった時点で足します。実装が無い段階で細則を増やしません。

---

## 1. 言語と並行性

### 1.1 Swift 6 / strict concurrency

- Swift 6 言語モード (`swiftLanguageModes: [.v6]`) を使い、strict concurrency を有効にする。
  警告を消すための言語モード引き下げは行わない。
- `@unchecked Sendable` と `nonisolated(unsafe)` は**原則禁止**。使う場合は、
  なぜ安全かをコメントで説明する (対象は C API 境界のみを想定)。

### 1.2 可変状態は actor に閉じ込める

- 共有される可変状態は `actor` に持たせる。`class` + ロックを新規に書かない。
- 例外は、同期コールバックの中で状態をその場で不可分に確定させる必要があり、`actor` へ hop すると
  不可分性や到着順が崩れる場合だけで、このときに限りロックで守る。その理由はコメントに書く。
- ドメインロジックは値型 + 純粋関数で書き、そもそも可変状態を持たない (§2)。

### 1.3 UI 境界は `@MainActor` 固定

**UI に触れる型、および `TerminalRenderer` の実装体は `@MainActor` に固定する。**

根拠 (Gate 1 スパイク §5.2 / 申し送り #3):

> libghostty のコールバックは C 関数ポインタであり、キャプチャも actor 隔離も表現できない。
> 一方 `NSView` / `NSApplication` は `@MainActor` である。素直に書くと
> `main actor-isolated property ... can not be referenced from a nonisolated context` が出る。

したがって、

- **C コールバックの入口で必ず main へ移す。** 手段は呼び出し元スレッドで使い分ける。
  両者は代替関係ではない。
  - **main thread 上で呼ばれることが保証されている**コールバックに限り、入口で
    `MainActor.assumeIsolated` を使う。保証の無いスレッドから呼ぶと実行時にクラッシュする。
  - それ以外 (`wakeup_cb` は libghostty の IO スレッドから飛んでくる) は
    `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }` で移す。
    `DispatchQueue.main.async` のクロージャは MainActor 隔離とは見なされないため、
    中の `assumeIsolated` を省略できない。
- 移送に `Task { @MainActor in ... }` を使わない。FIFO 順序が保証されず、
  ターミナルのイベント順が入れ替わり得るため。
- この規約を破ると、`nonisolated(unsafe)` がコードベース全体へ伝染する。
  スパイクではそれで逃がしたが、本体では逃がさない。

### 1.4 キャンセル

- 外部プロセスの実行中に呼び出し元の `Task` がキャンセルされた場合は、子プロセスへ終了シグナルを
  送り、直接起動したプロセスの終了・回収を確認してからキャンセルエラーを返す。
- キャンセル後に直接の子が終了コード 0 で終わっても、処理全体が完了していなければ成功結果へ
  置き換えない。キャンセルは呼び出し元が処理の継続を不要とした制御情報であり、握り潰すと
  後続処理が誤って進むため。
- `Foundation.Process` から終了できるのは直接起動したプロセスだけであり、そのプロセスが起動した
  孫プロセスは `ppid=1` で残り得る。プロセスグループ単位の終了は現在の実行層の対象外とする。

---

## 2. 設計スタイル

### 2.1 protocol-oriented + 値型中心

- **ドメインモデルは `struct` / `enum` + 純粋関数**で書く。
  入力を受け取って値を返すだけの関数にし、時刻・乱数・環境変数・ファイル・プロセスを
  関数の中から直接触らない (必要なら引数で受け取る)。
- **外部世界との境界は protocol で抽象化し、`actor` または `class` で実装する。**
  対象: tmux CLI 実行、git CLI 実行、SSH、PTY、libghostty、ファイル監視、SQLite。
- protocol は「境界」に対してだけ切る。テストのためだけの抽象を先回りして作らない。
- `ExistentialAny` を有効にしており (`Package.swift`)、existential は `any` の明示が必須。
  ジェネリクスで表現できる箇所は `some` / 型パラメータを優先し、`any` は
  異種コレクションや実装体の動的差し替えが必要な境界に限る。

### 2.2 モジュールと依存方向

```text
TerminalCore  ←  Adapters  ←  (将来) App / Host Core
```

- `TerminalCore`: ドメインモデル。**UI・外部プロセス・ネットワークに依存しない。**
  Foundation の値型 (`Date`、`URL` 等) までは許可する。
- `Adapters`: 外部世界との境界の実装。`TerminalCore` にのみ依存する。
- 依存は**一方向**。`TerminalCore` から `Adapters` を参照しない。
- platform 依存の実装は同じターゲット内で `#if os(macOS)` により表現する。iOS 実装が載る
  設計書 §24 Gate 2 までは、platform を理由にターゲットを分割しない。
- `TerminalCore` は platform 固有 API に依存させない。CI では arm64 iOS 17 simulator triple と
  iOS Simulator SDK による、テストターゲットを除く全ターゲットのコンパイルを確認するが、
  テストターゲット、実機向けコンパイル、simulator・実機での実行時動作までは保証しない。
- 新しいターゲットを足すときは、この図に位置づけられることを確認してから足す。

### 2.3 エラー

- 境界 (CLI 実行、パース、IO) では `throws` を使う。ドメインの純粋関数では
  「あり得ない入力」を型で排除し、`Optional` か明示的な結果型で返す。
- エラー集合が閉じている境界 (CLI 出力のパーサ等) では **typed throws**
  (`throws(ParseError)`) を使い、呼び出し側の網羅を型で担保する。
- 複数レコードのパースは fail-fast にせず、行番号・原文を保持した失敗と成功を
  **両方返す部分成功型**にする。1行の異常で全体を見失わないため。
  参照実装: `AgentWorkflowTerminal/Sources/Adapters/TmuxListPanes.swift`。
- 外部 CLI の出力バイト列は非失敗デコード (`String(decoding:_:as: UTF8.self)`) で受ける。
  不正バイトは U+FFFD へ置換して残し、1バイトの異常でレコード全体を失わない
  (部分成功型と同じ理由)。
- `fatalError` / `try!` / `as!` / 強制アンラップ (`x!`) は使わない。テストコードも同様
  (前提条件は Swift Testing の `#require` で表現できる)。担保の対応は §7。

---

## 3. TDD 方針

### 3.1 テストファーストにする範囲

**必須:**

- ドメインロジック (`TerminalCore` の純粋関数・状態遷移・優先順位判定)
- CLI 出力のパーサ (tmux / git / ripgrep)

先にテストを書き、失敗することを確認してから実装する。
リファレンス実装は `AgentWorkflowTerminal/Tests/TerminalCoreTests/WorktreeRepresentativeStateTests.swift`
(設計書 §12.2 の worktree 代表状態) を参照。

**テスト対象外 (書かない):**

- UI 描画そのもの
- libghostty 統合 (surface 生成、キー入力変換、IME、描画品質)

これらはスパイクと手動確認で担保する。手順は `Spikes/gate1/README.md` §8.9 / §10.8 にある。
自動テストで担保できない領域を、担保できているかのように見せるテストを書かない。

### 3.2 CLI 出力は fixture でテストする

tmux / git の出力パーサは、**実際に実行して得た出力をファイルへ保存し、それを入力にテストする。**

- 保存先: `AgentWorkflowTerminal/Tests/<Target>Tests/Fixtures/`
- ファイル名に、取得元のコマンドと**ツールの版数**を含める
  (例: `tmux-3.5a-list-panes.txt`)。tmux は版数で挙動が変わるため
  (Gate 1 申し送り #8)、版数の分からない fixture は価値が低い。
- fixture を手で書き換えて「きれいな入力」にしない。実際に出た文字列をそのまま置く。
- テストの中で `tmux` / `git` を実行しない。実行環境に依存するテストは CI で壊れる。

### 3.3 テストフレームワーク

**Swift Testing (`import Testing`) を標準とする。** XCTest は新規には使わない。
Swift 6 toolchain に同梱されており、追加依存が不要なため。

- テスト名と `@Suite` / `@Test` の表示名は日本語で書いてよい。
  設計書の節番号 (`§12.2` 等) を表示名に入れ、仕様との対応を追えるようにする。
- 失敗したら後続の検証が無意味になる前提条件は `#require`、検証そのものは `#expect` で書く。
- 同型の検証の繰り返しは `arguments:` で parameterize する。
- `@testable import` は非 public な宣言に触るときだけ使う。public API のテストは
  利用者と同じ `import` で書き、公開面の使い勝手もテストに語らせる。

---

## 4. 設計書由来の不変ルール

`docs/architecture.md` の**確定**事項のうち、コードに直接効くものです。
**これらに反する実装は、レビュー以前に書かない。**

| # | ルール | 出典 |
|---|---|---|
| 1 | **`Unknown` を `Working` / `Idle` へ丸めない。** 状態を確定できないときは `Unknown` を返す。`Unknown` は一級の状態であり、エラーでも中間表現でもない | §12.3 |
| 2 | **Claude Code 専用機能を作らない。** Agent 固有の知識は `AgentAdapter` 実装体の内側に閉じる。その外側に `if agent == .claudeCode` を書かない | §12.1 |
| 3 | **tmux を再実装しない。** pane 分割・キーバインド・session 管理は tmux の責務。アプリが持つのは最小操作 (split / close / select / zoom) と状態の読み取りだけ | §4.1 |
| 4 | **tmux と git は外部 CLI プロセスとして駆動する。** ライブラリ (libgit2 等) を組み込まない | §21.3 |
| 5 | **Git の書き込み操作を実装しない。** commit / merge / rebase / worktree 作成は Agent か素の shell へ委譲する。実装するのは読み取り (file browser / code viewer / diff / history / blame) だけ | §17 |
| 6 | **Terminal 本体は Agent Skills 無しで動く。** 観測できない phase 状態を発明しない | §26 |
| 7 | **`TerminalRenderer` の外へ libghostty API を漏らさない。** Gate 1 では libghostty 呼び出しを1ファイルに閉じたまま完了できている | §21.5 |

---

## 5. 依存関係

### 5.1 依存の追加

- **permissive license のみ**: MIT / BSD / ISC / Apache-2.0。
  GPL / LGPL / AGPL および license 不明のものは既定で不採用 (設計書 §23.1)。
- 依存を追加するときは、`docs/architecture.md` §23 の方針でレビューする。
  最低限、次を PR に書く: license、固定 version、transitive dependency の有無、
  外部 CLI か組み込みか。
- version は固定する。範囲指定で追随させない。
- **他プロジェクトのコードを「参考」としてコピーしない。**
  正規の依存として使うか、clean-room で実装する (設計書 §23.1)。

### 5.2 外部 CLI との付き合い方

- tmux / git / ripgrep は外部 CLI として呼ぶ。version 差は Adapter 境界で吸収する。
- サポートする下限 version を決め、`Adapters` 側で検出する。tmux の下限は 3.4
  (設計書 §4.3)。git の下限は未決定 (Issue #83)。
- CLI は shell を経由せず argv 配列で起動し、パイプ・リダイレクトに依存しない
  (`TerminalRendererConfiguration.command` は libghostty C API の制約により、renderer 内で
  POSIX shell quoting して shell 経由で実行するため、この外部 CLI 方針とは異なる)。
- 出力をパースする CLI は `LC_ALL=C` を明示して起動し、ロケール依存の出力
  (git のメッセージ・日付書式) をパーサへ流さない。
- tmux 3.4 は `LC_ALL=C` だけでは非 ASCII を `_` へ置換または削除するため、global option `-u` を
  サブコマンドより前へ併用する。`LC_ALL=C` と `-u` の併用で UTF-8 を保持できることを実測済み。
- 実行するバイナリの解決 (どの `tmux` / `git` を使うか) は Adapter に一元化し、
  呼び出し側のコードへ暗黙の `PATH` 依存を散らさない。

### 5.3 外部プロセスの実行

- stdout と stderr は協調スレッドプールを塞がない非同期 I/O で並行に読み切る。一方を先に待つと
  他方のパイプバッファが満杯になり、同期読み取りを Swift `Task` で並列化すると EOF 未到達時に
  並行性ランタイムまで停止するため。
- 汎用実行層は非ゼロの終了コードを結果値として返し、stderr も成功・失敗にかかわらず保持する。
  非ゼロ終了をエラーへ変換するかは、正常系でも stderr を使う CLI があるため、CLI ごとの Adapter が
  決める。
- 出力をパースするクライアントへ渡す環境変数は Adapter が明示的に組み立て、親環境を暗黙に
  継承しない。現状は同じ入口へ `new-session` 等も通せるため、限定環境が tmux server に保持され
  全 pane へ継承されることを API で防いでいない。環境別の入口は Issue #61 で設計する。
- タイムアウト時は SIGTERM、短い猶予、SIGKILL の順で直接の子を終了・回収し、出力 pipe は EOF を
  待たずに閉じる。直接の子が終了コード 0 でも孫が書き込み端を保持するとタイムアウトになり得るため、
  エラーには期限時点で判明している終了コードと部分 stdout / stderr を載せ、成功結果にはしない。
- タイムアウトの計時は子の起動成功後に始まる。呼び出し全体の壁時計には、指定値に加えて起動コスト、
  終了済みの子に対する最大50msの EOF 猶予または実行中の子に対する最大100msの停止猶予、callback の
  配達時間が加わる。
- 1実行の stdout と stderr の合計に既定8 MiBの上限を設ける。`yes` を100ms動かすだけで約385 MBまで
  RSSが増えたため、上限超過時は読み取りを止め、直接の子を終了・回収して専用エラーを返す。
- Task キャンセル時は §1.4 に従う。
- CLI ごとの Adapter は `ProcessRunning` のモックでテストする。実プロセスを使う実行層のテストは
  POSIX 標準ユーティリティに限り、版数差のある tmux / git は §3.2 のとおり通常のテストでは
  実行しない。実 server の確認は環境変数で opt-in する統合テストへ隔離する。

---

## 6. 実装上の既知の制約 (Gate 1 スパイク申し送り)

`Spikes/gate1/README.md` §S.3 の申し送り 15 項目のうち、**規約として守るべきもの**です。
詳細と実測値は同 README の該当節を参照してください。

| # | 制約 | どう扱うか | 出典 |
|---|---|---|---|
| 1 | upstream の `libtool` merge が Xcode 26.5 で壊れる | **ビルドスクリプトでシムを用意して担保する。** 各自の環境設定に依存させない | §3.4 |
| 2 | `ghostty_surface_foreground_pid` / `tty_name` が libghostty v1.3.1 に無い | **プロセス観測の一次情報源は tmux CLI** (`list-panes` 系)。renderer からプロセス情報を取らない | §3.3 / §8.10 |
| 3 | C コールバックと `@MainActor` の衝突 | §1.3 のとおり `TerminalRenderer` 実装体を `@MainActor` 固定 | §5.2 |
| 4 | `GHOSTTY_RESOURCES_DIR` と `terminfo` は兄弟ディレクトリ | バンドル構造の制約としてビルドスクリプト側で担保 | §3.3 |
| 5 | pane へのテキスト注入 | **`tmux load-buffer` + `paste-buffer -p` を使う。** `send-keys -l` は改行がそのまま実行になるため、1行テキスト以外に使わない | §8.8 |
| 6 | detach すると surface のプロセスが死ぬ | 同一 surface でのコマンド再実行 API が無い。タブのライフサイクル設計で吸収する | §8.2 |
| 7 | ディスプレイスリープ中は surface を生成できない | 生成失敗を正常系として扱い、遅延生成・リトライを用意する | §9.3 |
| 8 | tmux の版数が grapheme 表示に効く (3.4 は ZWJ を壊す) | サポート下限を 3.4 として検出し、fixture に版数を記録する (§3.2) | 設計書 §4.3 / Spikes/gate1/README.md §10.3 |
| 9 | `ime_point` の width に content scale が未適用 | **吸収する責務は `TerminalRenderer` 実装体**。上位へはスケール適用済みの値だけ渡す | §10.6 |
| 10 | East Asian Ambiguous は幅 1 として扱われる | 幅計算を自前で持たず、renderer / tmux の挙動に合わせる | §10.1 #9 |
| 11 | `window-size` の選択が複数クライアント体験を決める | マルチデバイス接続 (§4.2) の設計時に明示的に決める | §8.7 |
| 12 | libghostty の選択は pane 境界を無視する | 「pane 単位のコピー」は tmux の copy-mode に寄せる | §8.1 #22 |
| 13 | `scrollback-limit` がメモリ予算の主要パラメータ | 設定ファイルのロード経路 (`ghostty_config_load_file`) を `TerminalRenderer` に持たせる | §12.5 / §12.8 |
| 14 | メモリはアプリと tmux サーバの 2 か所に載る | `history-limit` の扱いを製品として決める | §12.5 |
| 15 | libghostty 側の split / tab は握り潰す | action callback で `false` を返す。設計書 §4.1 と整合 | §8.5 |

**スパイクのコードを本体へコピーしない。** `Spikes/` は使い捨てであり、
lint / format / テストの対象外です。参照実装として読み、本規約に沿って書き直します。

---

## 7. Lint / Format

| 用途 | ツール | 設定ファイル |
|---|---|---|
| フォーマット | `swift-format` | `.swift-format` |
| Lint | SwiftLint | `.swiftlint.yml` |

**選定理由:** フォーマッタは Swift 6 toolchain に同梱され `swift format` として追加インストール
無しに使える Apple 公式の `swift-format` を採用する (SwiftFormat は別途インストールが必要で、
CI とローカルの版数を揃える手間が増える)。Lint は代替が無く、依然 de facto standard である
SwiftLint を採用する。

ルールは**既定 + 軽い調整**に留めます。書式は `swift-format`、設計上まずい書き方は SwiftLint、
と責務を分けています。§1.1 / §2.3 の禁止事項は次で機械的に担保します。

| 禁止事項 | 担保するルール |
|---|---|
| `try!` | swift-format `NeverUseForceTry` |
| `as!` / 強制アンラップ (`x!`) | swift-format `NeverForceUnwrap` |
| `fatalError` / `@unchecked Sendable` / `nonisolated(unsafe)` | SwiftLint `custom_rules` |
| TODO / FIXME コメント (Issue 一元化) | SwiftLint `todo` |

§1.1 の例外 (C API 境界) を使うときは、理由コメントに加えて
`// swiftlint:disable:next` で行単位に局所化します。ファイル単位の disable はしない。

SwiftLint の既定ルールが本規約の方針と衝突したときは、**規約が勝ちます**。
方針そのものと衝突するルールは `disabled_rules` へ理由コメント付きで移し、
特定の行だけが例外ならその行を `swiftlint:disable:next` で局所化する。
ルールに合わせてコードを直すのは、その書き方に設計として同意できるときだけ。
SwiftLint の版数は CI で固定していないため、更新で既定ルールが増えて落ちることが
ある。その場合も同じ原則で処理する。

```shell
# フォーマット確認 / 適用
swift format lint --configuration .swift-format --recursive --strict \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift
swift format format --configuration .swift-format --recursive --in-place \
  AgentWorkflowTerminal/Sources AgentWorkflowTerminal/Tests AgentWorkflowTerminal/Package.swift

# Lint (要 `brew install swiftlint`)
swiftlint lint --config .swiftlint.yml
```

`Spikes/` は両方の対象外です (`.swiftlint.yml` の `excluded`)。

CI (`.github/workflows/ci.yml`) は swift-format lint と SwiftLint の両方を実行します。
ローカルの SwiftLint 導入 (`brew install swiftlint`) は任意のままですが、CI では必須です。

---

## 8. コメントとコミット

### 8.1 情報の置き場所

**コード = How / テストコード = What / コミットログ = Why / コードコメント = Why not。**

| 置き場所 | 担当する情報 | 意味 |
|---|---|---|
| コード | **How** | 実装そのものが「どうやるか」を語る。コメントで実装をなぞらない |
| テストコード | **What** | テスト名とアサーションが仕様 (何をするか) を語る |
| コミットログ | **Why** | なぜこの変更をするのかを本文に書く |
| コードコメント | **Why not** | 「なぜ素直な書き方をしなかったか」「コードから読めない制約・落とし穴」だけを書く。それ以外のコメントは書かない |

判断に迷ったら「このコメントを消したとき、読み手は何を失うか」を問う。
失うものが**コードを読めば分かること**なら、そのコメントは消す。

### 8.2 doc コメント (`///`) も同じ原則で書く

公開 API だからといって例外にしません。

- 型名・シグネチャから自明な説明の**繰り返しは禁止**する
  (`/// タブ優先度を計算する` のような言い換えは書かない)。
- 書いてよいのは、**コードから読めない契約・制約**だけ。
  単位・座標系、`nil` や `Optional` の意味、呼び出し順の前提、実装体に課す義務、落とし穴。
- **設計書の節番号参照 (`§12.3` 等) は「コードから読めない根拠」であり、Why not として有効。**
  出典の書き方は §9 に従う。値の出どころ (`tmux` の `#{pane_id}` 等) も同様に有効。
- 結果として、doc コメントの無い公開 API があってよい。名前で足りているということです。

### 8.3 対象範囲

- `// MARK:` は navigation の道具であり、この規約の対象外。
- `Spikes/` 配下は**この規約の対象外**。使い捨てのスパイク品質を隔離する領域であり、
  lint / format / テストと同じく本規約も適用しません (§6 末尾)。

### 8.4 Conventional Commits

**Conventional Commits** に従います (既存の慣習の明文化)。

```text
<type>: <要約>
```

使う type: `feat` / `fix` / `docs` / `test` / `refactor` / `build` / `ci` / `chore`。

- 要約は命令形・現在形。
- **本文には Why を書く** (§8.1)。差分を読めば分かる「何をしたか」の列挙で本文を埋めない。
- 1コミット1意味単位。規約変更と実装を混ぜない。
- 設計書 (`docs/architecture.md`) の**状態区分を変えるコミットは単独にする。**
  実装コミットのついでに 確定 / 現在の推奨 の区分を動かさない。

---

## 9. ドキュメント

- `docs/` 配下は日本語で書く。
- `docs/architecture.md` の 確定 / 現在の推奨 / 未確定 / 対象外 の区別を維持する。
  昇格はユーザーの明示的な判断があるときだけ行う (`/decide`)。
- コード中のコメントは日本語で書いてよい。何を書くかは §8 に従う。
  設計書由来のルールには**出典の節番号を必ず書く** (例: `設計書 §12.3`)。
  スパイクの申し送り由来なら `Spikes/gate1/README.md §5.2` のように書く。
  「なぜそう書いてあるか」を後から追えることを、コメントの第一目的とする。
