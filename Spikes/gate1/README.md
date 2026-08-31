# Gate 1 スパイク — M0 / M1 / M2 / M3 / M4 実施記録

- 実施日: 2026-08-31
- ブランチ: `spike/gate1-terminal-poc`
- 対象: `PLAN.md` の **M0(準備)** / **M1(SwiftUI ウィンドウで zsh が動く)** / **M2(tmux attach と操作検証)** /
  **M3(Claude Code / Codex の TUI 実動 + VT互換性 + 日本語・絵文字・grapheme width)** /
  **M4(大量出力・長時間稼働・メモリ)**
- 状態: **M0 / M1 / M2 / M3 / M4 すべて完了。** 判定サマリは下記。

> この文書は「やってみて何が分かったか」の記録である。
> `docs/architecture.md` の状態区分(確定／現在の推奨／未確定／対象外)は一切変更していない。
> libghostty は依然 §21.1 の「現在の推奨」であり、本スパイクは昇格も降格もしない。

---

## Gate 1 判定サマリ

**この節は判断材料の整理であり、「Gate 1 成立 / 不成立」の最終判断はユーザーが行う。**
スパイクの役割は §24 のチェック項目を実測で潰し、撤退基準(PLAN.md §7)に触れるものが
あるかどうかを示すところまでである。

### S.1 §24 チェックリストの最終状態

凡例: ✅ 確認済み / ⚠️ 条件付き・制約あり / ❌ 破綻 / ❓ 未検証(要手動確認)

| §24 の項目 | 最終状態 | 根拠 | 残っている確認 |
|---|---|---|---|
| **VT互換性** | ✅ | §10.2(色 16/256/truecolor、SGR 全種、box drawing、DECSTBM、alternate screen、`less` / `vim`) | `vttest` 未導入のためスキップ(§10.1 #7)。網羅検証は本実装後 |
| **Metal描画とresize** | ✅ | §4.2(cols/rows がピクセル幅に線形追随)、§12.3(**大量出力中でもリサイズが効く**) | 外部ディスプレイ間の移動・scale factor 変化は**未検証**(実機に外部ディスプレイ無し) |
| **IME、日本語入力** | ⚠️ | §10.6(`preedit` 描画 ✅ / `ime_point` 取得 ✅) | ❓ **実際のかな漢字変換操作が未検証(要手動)**。手順は §10.8。`ime_point` の width スケール問題あり |
| **絵文字、grapheme width** | ⚠️ | §10.3(全角幅・VS15/16・肌色修飾・国旗は ✅) | ⚠️ **ZWJ シーケンスは tmux 3.4 が壊す**(libghostty 単体では正しい)。tmux 下限版数の決定が必要 |
| **copy／paste** | ✅ | §8.6(⌘C / ⌘V、bracketed paste、複数行・日本語) | ❓ 物理キーボード経由は未検証(§8.9) |
| **selection** | ⚠️ | §8.6(mouse on/off・Shift バイパスとも動作) | ⚠️ libghostty の選択が **pane 境界を無視する**(§8.1 #22)。仕様上の制約 |
| **URL／path hit testing** | ⚠️ | §8.6(URL hover / click / OSC 8 は ✅) | ⚠️ path の hit testing は部分的。**mouse reporting ON のとき hover 検出が抑止される** |
| **mouse protocol** | ✅ | §8.1 #16〜21(pane 選択・境界リサイズ・ホイールで copy-mode) | ❓ 物理マウス / トラックパッド慣性 / 右クリックは未検証(§8.9) |
| **tmux split／zoom／attach／detach** | ✅ | §8.2〜8.5(CLI 操作・キーバインドとも表示が即時追随、衝突ゼロ) | ⚠️ **detach すると surface のプロセスが死ぬ**(§8.2)。タブのライフサイクル設計が必要 |
| **大量output** | ✅ | §12.2(50MB の `cat` が tmux 経由 3.2 秒 / 直結 0.75 秒)、§12.3(**出力中も UI 応答は劣化しない**) | — |
| **長時間稼働** | ⚠️ | §12.6(35 分ソーク: メモリはプラトー、リーク傾向なし) | ❓ **数時間〜数日規模は未検証**。本実装後に実作業で計測する |
| **memory** | ✅ | §12.4(起動 98MB / 出力ピーク 143MB / 出力後 102MB)、§12.5(`scrollback-limit` が上限として機能) | ❓ **複数 surface(5〜10)同時と `ghostty_surface_free` のリークは未検証**(§12.7) |
| **AppKit bridgeが必要な範囲** | ✅ | §5.1(一覧化済み。`NSTextInputClient` を M3 で追加) | 判断事項: 「ターミナル面は AppKit の `NSView` 1 枚」を許容するか(撤退基準 §7-7) |

### S.2 撤退基準(PLAN.md §7)への当てはめ

| # | 撤退基準 | 判定 | 根拠 |
|---|---|---|---|
| 1 | 致命: `GhosttyKit.xcframework` を自力ビルドできない | **抵触なし** | §3.2(clean ビルド 1分47秒)。ただし `libtool` のシムが必要(§3.4) |
| 2 | 致命: Claude Code / Codex の TUI が実用にならない | **抵触なし** | §10.4 / §10.5。両者とも表示崩れ・入力取りこぼし無し |
| 3 | 致命: 日本語 IME が実用にならない | **抵触なし(条件付き)** | §10.6。preedit 描画・候補位置 API とも動作。**実変換操作は未検証** |
| 4 | 致命: tmux attach 下で split / zoom / detach / mouse が壊れる | **抵触なし** | §8。キーバインド衝突ゼロ |
| 5 | 致命: ライセンス上の障害 | **抵触なし** | §3.5 / PLAN.md §4.8(ghostty は MIT。tmux / ripgrep は外部 CLI) |
| 6 | 重大: 大量出力で入力応答が失われる / 長時間で RSS が単調増加 | **抵触なし(観測範囲では)** | §12.3(応答性は劣化せず)、§12.6(35分でプラトー)。**長期は未検証** |
| 7 | 重大: AppKit bridge の必要範囲が大きすぎる | **要判断** | §5.1。周辺 UI は SwiftUI で書けるが、**ターミナル面は AppKit の `NSView` 1 枚**になる |
| 8 | 重大: API 非安定性が実害として現れる | **現時点では未発生** | v1.3.1 にピン留めして作業。upstream `main` との差分(存在しない関数)は §3.3 に記録 |
| 9 | 重大: `TerminalRenderer` による隔離が成立しない | **抵触なし** | libghostty 呼び出しは `GhosttyTerminalView.swift` 1 ファイルに閉じたまま M1〜M4 を完了できた |

### S.3 本体実装フェーズへの申し送り

M1〜M4 で判明した、**本体の設計・実装に直接効く事項**の一覧(詳細は各節)。

| # | 事項 | 節 |
|---|---|---|
| 1 | **ビルド: upstream の `libtool` merge が Xcode 26.5 で壊れる。** シムが必要 | §3.4 |
| 2 | **`ghostty_surface_foreground_pid` / `tty_name` は v1.3.1 に存在しない。** プロセス観測は `tmux list-panes` 系が**前提**になる | §3.3 / §8.10 |
| 3 | **Swift 6 並行性: C コールバックの入口で必ず main へ移す規約が要る。** `TerminalRenderer` 実装体は `@MainActor` 固定 | §5.2 |
| 4 | **`GHOSTTY_RESOURCES_DIR` と `terminfo` は兄弟ディレクトリに置く**(バンドル構造の制約) | §3.3 |
| 5 | **pane へのテキスト注入は `load-buffer` + `paste-buffer -p`。** `send-keys -l` は改行がそのまま実行になる | §8.8 |
| 6 | **detach すると surface のプロセスが死ぬ。** 同一 surface でのコマンド再実行 API が無く、surface の作り直しかラッパー起動が要る | §8.2 |
| 7 | **ディスプレイスリープ中は surface を作れない。** 生成失敗時のフォールバック(遅延生成・リトライ)が要る | §9.3 |
| 8 | **tmux の版数が grapheme 表示に効く**(3.4 は ZWJ を壊す)。サポート下限版数を決める必要がある | §10.3 |
| 9 | **`ime_point` の width だけ content scale が未適用。** ホスト側で吸収する責務を `TerminalRenderer` に置く | §10.6 |
| 10 | **East Asian Ambiguous は幅 1 として扱われる**(tmux 有無で差なし)。設定で変えられるかは未調査 | §10.1 #9 |
| 11 | **`window-size` の選択(smallest / latest / largest)は複数クライアント同時接続時の体験を決める**(§4.2 のマルチデバイス想定に直結) | §8.7 |
| 12 | **libghostty の選択は pane 境界を無視する。** 「pane 単位のコピー」は tmux 側 copy-mode に寄せる判断が要る | §8.1 #22 |
| 13 | **`scrollback-limit` がメモリ予算の主要パラメータ。** 設定ロード経路(`ghostty_config_load_file`)が `TerminalRenderer` に要る | §12.5 / §12.8 |
| 14 | **メモリはアプリと tmux サーバの 2 か所に載る。** `history-limit` を製品としてどう扱うかを決める必要がある | §12.5 |
| 15 | **libghostty 側の split / tab は action callback で `false` を返して握り潰す**(§4.1 確定と整合)。実証済み | §8.5 |

### S.4 未検証で残ったもの(要手動確認 / 本実装後)

1. 実 IME(かな漢字変換)の操作一式 — 手順は §10.8
2. 物理キーボード / 物理マウス / トラックパッド、描画品質・体感遅延 — 手順は §8.9
3. 外部ディスプレイ間の移動、スリープ / 復帰、background / foreground 復帰 — §12.7
4. 数時間〜数日規模の長時間稼働 — §12.7
5. 複数 surface(5〜10)同時のメモリ / CPU、`ghostty_surface_free` のリーク — §12.7
6. `vttest` 相当の網羅的な VT 検証 — §10.2

---

## 0. ピン留め方針(この作業で確定した前提)

| 項目 | 値 | 根拠 |
|---|---|---|
| ghostty | **タグ `v1.3.1`**(commit `332b2ae`) | PLAN.md §4.7 案A。iOS スライスが残る最後の版であり Gate 2 の選択肢を閉じない |
| zig | **0.15.2**(Homebrew `zig@0.15`、keg-only) | `build.zig.zon` の `minimum_zig_version = "0.15.2"` |

upstream `main` は使わない。シェルプロファイルは書き換えず、`scripts/build-ghostty.sh` が
`/opt/homebrew/opt/zig@0.15/bin` を明示的に PATH へ通す。

---

## 1. ビルド・実行手順

```shell
# 1) libghostty (GhosttyKit.xcframework) をビルドする
#    初回は Metal Toolchain の導入が必要 (約 690MB)
xcodebuild -downloadComponent MetalToolchain
Spikes/gate1/scripts/build-ghostty.sh          # CLEAN=1 でキャッシュを捨てて再ビルド

# 2) TerminalSpike.app を組み立てる
Spikes/gate1/scripts/build-app.sh              # 既定 debug。release も可

# 3) 起動する
open Spikes/gate1/build/TerminalSpike.app
# または
Spikes/gate1/build/TerminalSpike.app/Contents/MacOS/TerminalSpike
```

環境変数:

| 変数 | 意味 |
|---|---|
| `TERMINAL_SPIKE_COMMAND` | surface の command。既定 `/bin/zsh`。M2 では `tmux -L gate1-spike new-session -A -s gate1-spike` |
| `TERMINAL_SPIKE_USER_CONFIG=1` | `~/.config/ghostty/config` を読み込む(既定は読まない) |
| `TERMINAL_SPIKE_RESIZE_TEST=1` | 起動後に 3 サイズへリサイズして `ghostty_surface_size()` をログ出力する計測フック |
| `TERMINAL_SPIKE_EXIT_AFTER=<秒>` | 指定秒後に自動終了(検証用) |
| `TERMINAL_SPIKE_CONTROL=<path>` | **M2 の制御チャネル**。このファイルへ追記した行をコマンドとして実行する(§9.2) |
| `TERMINAL_SPIKE_CONFIG_FILE=<path>` | **M4 で追加**。`ghostty_config_load_file` でこの設定ファイルを読む。`scrollback-limit` の実験用(§11.1)。ユーザーの `~/.config/ghostty/config` は読まない |

M2 の検証は `scripts/m2-harness.sh`、M3 は `scripts/m3-harness.sh`、M4 は `scripts/m4-harness.sh`
から駆動する(§9.1 / §11.1)。いずれも同じ隔離方式(専用ソケット `-L gate1-spike`)を共有する。

```shell
export M2_RUN_DIR=/tmp/gate1-m2
Spikes/gate1/scripts/m2-harness.sh launch 1100x700   # 起動して gate1-spike に attach
Spikes/gate1/scripts/m2-harness.sh ctl 'key ctrl+q' 'sleep 150' 'key z'
Spikes/gate1/scripts/m2-harness.sh shot 99-something # evidence/m2-99-something.png
Spikes/gate1/scripts/m2-harness.sh teardown          # アプリ終了 + tmux サーバ破棄
```

---

## 2. 採った構成と理由

| 判断 | 採用 | 理由 |
|---|---|---|
| プロジェクト形式 | **SwiftPM executable(`TerminalSpike/Package.swift`)** | `project.pbxproj` を手書きせずに済む。`.binaryTarget` に `../vendor/ghostty/macos/GhosttyKit.xcframework` という**相対パス(`..` を含む)を SwiftPM が受け付ける**ことを確認したので、xcframework のコピーも不要 |
| 実行形態 | **手組みの `.app` バンドル**(`scripts/build-app.sh`) | SwiftPM の裸の実行ファイルだと Info.plist もバンドル ID も無く、NSApplication の activation が不安定。加えて libghostty のリソース配置(§3.3)にバンドル構造が必要 |
| libghostty 呼び出し | **`Sources/TerminalSpike/GhosttyTerminalView.swift` 1 ファイルに隔離** | §21.5。`TerminalRenderer` protocol に載る候補には `// [RENDERER]` を付けてある |

`xcodegen` 等の追加ツールは使っていない。

---

## 3. M0 の結果

### 3.1 環境記録(PLAN.md §3 / R10 の記録項目)

| 項目 | 値 |
|---|---|
| macOS | 26.5.2 (25F84) / arm64 |
| Xcode | 26.5 — `/Applications/Xcode.app/Contents/Developer` |
| Swift | 6.3.2 (swiftlang-6.3.2.1.108), target `arm64-apple-macosx26.0` |
| zig | 0.15.2 (`/opt/homebrew/opt/zig@0.15/bin/zig`, keg-only) |
| **tmux** | **3.4** |
| Claude Code | 2.1.251 |
| Codex CLI | 0.147.0 |
| ghostty | v1.3.1 (`332b2ae`) |

### 3.2 所要時間

| 工程 | 実測 |
|---|---|
| `brew install zig@0.15`(llvm@20 / lld@20 を含む) | 約 2 分 |
| `git clone --depth 1 --branch v1.3.1` | 数十秒 |
| `xcodebuild -downloadComponent MetalToolchain` | 687.9MB のダウンロード。数分 |
| `zig build`(clean、依存はグローバルキャッシュ済み) | **1 分 47 秒**(user 4m20s / sys 33s) |
| 差分ビルド | 約 3 秒 |

### 3.3 PLAN.md との差分(重要)

1. **出力先が違う。** PLAN.md §4.2 は `zig-out/macos/GhosttyKit.xcframework` と書いているが、
   v1.3.1 の `src/build/GhosttyXCFramework.zig` は `out_path = "macos/GhosttyKit.xcframework"`
   であり、実際にはリポジトリ直下の **`macos/GhosttyKit.xcframework`** に出る。
   `zig-out/` に入るのは `share/`(terminfo・shell-integration・themes)と `include/`、
   および `libghostty-vt` の dylib のみ。

2. **`GHOSTTY_RESOURCES_DIR` の指す先。** `zig-out/share/ghostty` を指す。
   libghostty は子プロセスへ `TERMINFO=<resources_dir>/../terminfo` を渡す
   (`src/termio/Exec.zig`)ので、`ghostty/` と `terminfo/` が**兄弟である**配置が必須。
   `build-app.sh` は `.app/Contents/Resources/{ghostty,terminfo}` にこの構造を作る。

3. **`ghostty_surface_foreground_pid` / `ghostty_surface_tty_name` は v1.3.1 に存在しない。**
   PLAN.md §4.4 は upstream main のヘッダを読んで書かれている。v1.3.1 の `ghostty.h`
   にはこの 2 つが無い(`ghostty_surface_process_exited` はある)。
   → **Gate 3(Agent Adapter)への申し送り:** v1.3.1 にピン留めする限り、surface から
   プロセスを直接観測する手段は無い。`tmux list-panes -F '#{pane_pid}'` 系が必須になる。
   PLAN.md §6.3 の懸念は「tmux を挟むと何が返るか」以前に「そもそも API が無い」だった。

### 3.4 詰まった点と回避策 — upstream の `libtool` merge が壊れている

**これが M0 で最も時間を食った問題であり、記録に値する。**

- 症状: `zig build` は成功し `GhosttyKit.xcframework` も生成されるのに、
  リンク時に `Undefined symbols: _ghostty_init, _FT_*, _glslang_*, _Oniguruma*, ...` が大量に出る。
- 原因: ghostty は `libtool -static -o libghostty-fat.a <入力.a ...>` で依存を 1 本にまとめる
  (`src/build/LibtoolStep.zig`)。Xcode 26.5 同梱の `/usr/bin/libtool` は zig が生成した
  アーカイブを入力にすると、**一部のメンバ `.o` を警告だけ出して黙って捨てる**。

  ```
  libtool: warning: 64-bit mach-o member 'libghostty_zcu.o' not 8-byte aligned
  ```

  実測: `libghostty.a` 単体を `libtool -static` に通すと 8 メンバ中
  `vt.o` / `wuffs-v0.4.o` / `libghostty_zcu.o` の 3 つが消える。
  全体では出力アーカイブが **282 メンバ 141MB → 146 メンバ 54MB** に痩せていた。
  ghostty のコード本体(`libghostty_zcu.o`)ごと落ちるので `_ghostty_init` すら引けない。
- 回避策: **`llvm-libtool-darwin` に差し替える。** 同じ入力を正しく処理する。
  `build-ghostty.sh` が `Spikes/gate1/.build-shim/libtool` というシンボリックリンクを作り、
  PATH の先頭に置くことで ghostty 側を一切改変せずに差し替えている。
  `llvm@20` は `zig@0.15` の依存として Homebrew が自動で入れるため追加インストールは不要。
  スクリプトはビルド後に `nm -g` で `_ghostty_init` の有無を検査し、再発時に落ちる。
- 申し送り: これは **ghostty v1.3.1 × Xcode 26 系の組み合わせ固有**の問題と思われる。
  upstream 追随方針(§4.7)を決める際の材料になる。撤退基準 §7-1
  「upstream から自力ビルドできない」には**該当しない**(標準ツールチェーン内で解決した)。

### 3.5 その他ハマりどころ

- **Metal Toolchain が別コンポーネント。** Xcode 26 では `metal` が既定で入っておらず、
  `xcodebuild -downloadComponent MetalToolchain` が必要。PLAN.md §4.2 は前提として
  1 行触れているだけなので、`build-ghostty.sh` の冒頭で明示的に検査するようにした。
- **SwiftPM は static library の XCFramework にリンクフラグを自動付与しない。**
  `.binaryTarget` を宣言すると `.a` をビルドディレクトリへコピーはするが `-l` を出さない。
  `Package.swift` で `.linkedLibrary("ghostty-fat")` を明示している。
  加えて upstream の `macos/Ghostty.xcodeproj` に合わせて `-lstdc++` と `Carbon.framework` を指定。
  それ以外のフレームワーク(Metal / AppKit / CoreText 等)は zig が `.o` に埋めた
  `LC_LINKER_OPTION` で自動リンクされ、明示不要だった。
- **無害な警告が出る。** ビルド時に
  `umbrella header for module 'GhosttyKit' does not include header '/ghostty/vt/*.h'`
  が十数件出る。`xcodebuild -create-xcframework -headers include/` が libghostty-vt の
  ヘッダまで同梱する一方、umbrella header の `ghostty.h` はそれらを include しないため。
  リンクにも動作にも影響しない。スパイク側のコードからの警告は 0 件。

---

## 4. M1 の結果

### 4.1 動いたこと

- `ghostty_init` → `ghostty_config_new/finalize` → `ghostty_app_new`(runtime callbacks)
  → `NSView` → `ghostty_surface_new` の順で surface が作れる。
- `NSViewRepresentable` 経由で SwiftUI の `WindowGroup` に載る。
- **`command = /bin/zsh` で対話シェルが起動し、プロンプトが表示される。**
  実際には macOS 既定の `login -flp <user> ... exec -l /bin/zsh` 経由で起動される
  (libghostty 側の挙動)。ユーザーの zsh 設定がそのまま効く。
- **terminfo が正しく引ける。** 子プロセスの環境は
  `TERM=xterm-ghostty` / `TERMINFO=<app>/Contents/Resources/terminfo` /
  `COLORTERM=truecolor` / `GHOSTTY_SHELL_FEATURES=cursor:blink,path,title`。
  `infocmp -1 xterm-ghostty` がバンドル内 DB から解決できることを確認。
- **shell integration が効いている。** OSC でタイトルが飛んできて、
  `GHOSTTY_ACTION_SET_TITLE` ハンドラがウィンドウタイトルを `~/w/s/agent-workflow-terminal`
  に更新した(スクリーンショット参照)。
- Metal 描画。ウィンドウにテキストが正常に描かれる(証跡 `evidence/m1-zsh.png`)。
- **リサイズが追随する**(下記 4.2)。

### 4.2 resize の実測(`TERMINAL_SPIKE_RESIZE_TEST=1`)

Retina(backingScaleFactor = 2.0)、外部ディスプレイなし。

| ウィンドウ(pt) | `ghostty_surface_size()` |
|---|---|
| 900 × 560 | cols=112 rows=32 px=1800×1120 cell=16×34 |
| 520 × 380 | cols=64 rows=22 px=1040×760 cell=16×34 |
| 1200 × 800 | cols=149 rows=46 px=2400×1600 cell=16×34 |

- `ghostty_surface_set_size` は**フレームバッファ(ピクセル)サイズ**を取る。
  point をそのまま渡すと Retina で半分のグリッドになる。`convertToBacking` が必須。
- cell size がスケール間で一定(16×34 px)であり、columns/rows がピクセル幅に線形に追随している。

### 4.3 やっていないこと / 分かっていないこと

- **ウィンドウ描画の目視確認はユーザーに委ねる。** 証跡は `evidence/m1-zsh.png`
  (`screencapture -l <windowID>` でウィンドウのみを撮影)。
  スクロール、カーソル点滅、フォント品質、色再現などの主観的な描画品質は
  実際に触って本家 `Ghostty.app` と見比べてほしい。
- **キー入力を自動検証していない。** アクセシビリティ権限が無く、
  `System Events` からの入力送出もウィンドウ列挙もできなかった。
  `keyDown` / `keyUp` / `flagsChanged` は実装済みだが**未検証**。
- **IME は未実装。** `NSTextInputClient` 準拠と `ghostty_surface_preedit` /
  `ghostty_surface_ime_point` の接続は M3 の作業として残している。
- 外部ディスプレイ間の移動(`set_display_id` / scale factor 変化)。
  コードは書いたが、実機に外部ディスプレイが無く未検証。
- clipboard は read/write コールバックを最小実装したのみ(`text/plain` だけ)。
  OSC 52 の確認ダイアログは素通し。M2 の検証対象。

---

## 5. §24 チェック項目に対する M1 時点の所見

| §24 項目 | 状況 | 所見 |
|---|---|---|
| **Metal描画とresize** | ✅ 確認 | libghostty が渡した `NSView` を layer-hosting 化し、自前の `IOSurfaceLayer` を差し込む(`src/renderer/Metal.zig`)。**ホスト側は `layer` / `wantsLayer` / `draw` に一切触らない**。`ghostty_surface_draw` を毎フレーム呼ぶ必要も無く、描画は libghostty が自走する。resize は 4.2 の通り追随 |
| **AppKit bridgeが必要な範囲** | ✅ 一覧化(下記 5.1) | 「SwiftUI + 必要最小限の AppKit」(§21.1)に収まるが、**ターミナル本体は事実上フル AppKit の `NSView`** になる。撤退基準 §7-7 に照らして要判断 |
| **VT互換性(基礎)** | △ 部分的 | terminfo が引け、shell integration の OSC が往復し、プロンプトが崩れずに出る所まで。網羅的な検証は M3 |
| tmux split/zoom/attach/detach | ✅ M2 で確認 | §8 参照 |
| mouse protocol | ✅ M2 で確認 | §8 参照 |
| copy/paste・selection・URL hit testing | ✅ M2 で確認 | §8 参照 |
| IME・日本語・絵文字・grapheme width | 未着手 | M3 |
| 大量output・長時間稼働・memory | ✅ M4 で確認 | §12 参照。起動直後 RSS ≒ 100MB という M1 時点の参考値は M4 でも再現した |

### 5.1 AppKit bridge が必要だった範囲(§24 の主要チェック項目)

**SwiftUI だけで済む部分**
- ウィンドウ・シーン定義(`WindowGroup`)、既定サイズ、レイアウト
- 周辺 UI(将来の Viewer Drawer、タブバー等)

**`NSView` サブクラスが必須の部分**(実際に書いたもの)

| 用途 | 必要な override | 理由 |
|---|---|---|
| surface の受け皿 | `viewDidMoveToWindow` | libghostty に `NSView*` を渡す必要がある。SwiftUI View では不可 |
| resize | `setFrameSize` / `convertToBacking` | ピクセルサイズが要る |
| Retina / ディスプレイ移動 | `viewDidChangeBackingProperties` | `backingScaleFactor`、`NSScreenNumber` |
| フォーカス | `acceptsFirstResponder` / `becomeFirstResponder` / `resignFirstResponder` | `ghostty_surface_set_focus` |
| キー入力 | `keyDown` / `keyUp` / `flagsChanged` | keycode・左右修飾キー・`characters(byApplyingModifiers:)` は SwiftUI の `onKeyPress` では取れない |
| IME(**M3 で実装済み**) | `NSTextInputClient` 準拠、`interpretKeyEvents`、`markedText`、`doCommand(by:)` の握り潰し | preedit(`ghostty_surface_preedit`)と候補ウィンドウ位置(`ghostty_surface_ime_point`)。SwiftUI にこの経路は無い。§10.6 |
| マウス | `updateTrackingAreas` / `mouseDown` 等 / `scrollWheel` | tracking area と scroll phase / momentum |
| アプリのフォーカス | `NSApplicationDelegate` + 通知 | `ghostty_app_set_focus` |

**結論:** Drawer やタブなど**周辺 UI は SwiftUI で書けるが、ターミナル面そのものは
AppKit の `NSView` を丸ごと 1 枚書くことになる**。これは Ghostty.app 本体と同じ構造であり
避けられない。ただし範囲は 1 ファイルに閉じており、`TerminalRenderer` protocol の
背後に隠せる見込み。現時点で撤退基準 §7-7 には抵触しないと判断する
(最終判断は M2〜M4 の結果を見てから)。

### 5.2 Swift 6 並行性との相性(新しく判明した論点)

libghostty のコールバックは C 関数ポインタであり、キャプチャも actor 隔離も表現できない。
一方 `NSView` / `NSApplication` は `@MainActor` である。素直に書くと
`main actor-isolated property ... can not be referenced from a nonisolated context` が出る。

スパイクでは `nonisolated(unsafe)` と `MainActor.assumeIsolated` で逃がした。
**本体では `TerminalRenderer` の実装体を `@MainActor` に固定し、
C コールバックの入口で必ず main へ移す規約を決める必要がある。**
`wakeup_cb` は libghostty の IO スレッドから飛んでくるため、`DispatchQueue.main.async`
で `ghostty_app_tick` を呼ぶ形が必要(本家 Ghostty.app も同じ方式)。

### 5.3 split action の握り潰し(PLAN.md §6.1 の予行)

設計書 §4.1(確定)に従い、libghostty 側の split は使わない。
`GHOSTTY_ACTION_NEW_SPLIT` / `TOGGLE_SPLIT_ZOOM` / `GOTO_SPLIT` / `RESIZE_SPLIT` /
`EQUALIZE_SPLITS` / `NEW_TAB` / `NEW_WINDOW` は action callback で **`false` を返して
「ホストは対応しない」と伝える**方式にした。実際にキーバインドが飛んでくるかは M2 で確認する。

---

## 6. ディレクトリ構成

```
Spikes/gate1/
├── PLAN.md                     調査と計画(先行作成)
├── README.md                   この文書
├── scripts/
│   ├── build-ghostty.sh        GhosttyKit.xcframework のビルド (M0)
│   ├── build-app.sh            TerminalSpike.app の組み立て (M1)
│   ├── m2-harness.sh           M2 検証ハーネス (launch / ctl / shot / teardown)
│   ├── m3-harness.sh           M3 検証ハーネス (m2 を再利用 + inject / run / launch-bare)
│   ├── m3-checks/              M3 の検証スクリプト (pane 内で実行する)
│   │   ├── vt-color.sh         256色 / truecolor / SGR / box drawing
│   │   ├── vt-scrollregion.sh  DECSTBM スクロールリージョン
│   │   ├── wide.sh             日本語 / 絵文字 / grapheme の目視確認
│   │   └── width-probe.sh      DSR(CPR) で grapheme width を数値確認
│   ├── m4-harness.sh           M4 検証ハーネス (m3 を再利用 + ping / mem / sampler / footprint)
│   └── m4-checks/              M4 の検証スクリプト (pane 内で実行する)
│       ├── throughput.sh       大量出力スループット計測
│       ├── fastui.sh           高速更新 TUI (進捗バー + top)
│       └── soak.sh             中期ソーク (周期出力 + burst)
├── TerminalSpike/
│   ├── Package.swift           SwiftPM executable + binaryTarget
│   └── Sources/TerminalSpike/
│       ├── TerminalSpikeApp.swift    SwiftUI App / AppDelegate / 計測フック
│       ├── GhosttyTerminalView.swift libghostty 呼び出しの唯一の場所
│       └── SpikeControl.swift        M2/M3 の制御チャネル (GhosttyKit を import しない)
├── evidence/
│   ├── m1-zsh.png              M1 の証跡(ウィンドウのみ)
│   ├── m2-01..23-*.png         M2 の証跡
│   ├── m3-00..37-*.png         M3 の証跡
│   ├── m4-01..07-*.png         M4 の証跡
│   ├── m4-throughput.csv       M4 スループット生データ
│   ├── m4-mem-*.csv            M4 メモリ生データ (tmux / bare / scrollback)
│   ├── m4-soak-samples.csv     M4 ソークのサンプリング (15秒間隔)
│   └── m4-footprint-*.txt      footprint(1) の全文
├── vendor/ghostty/             ghostty v1.3.1 の shallow clone (git 管理外)
├── build/                      TerminalSpike.app (git 管理外)
└── .build-shim/                libtool シム (git 管理外)
```

`vendor/` `build/` `.build-shim/` `TerminalSpike/.build/` は `.gitignore` 済み。
`evidence/` も `.gitignore` 済み(スクリーンショット等は容量が大きいため Git 管理せず、ローカルにのみ保持する)。

---

## 7. M2 の進め方(実際に採った方法)

### 7.1 ユーザーの tmux 環境を汚さないための隔離

**専用の tmux サーバソケット `-L gate1-spike` を使った。** セッション名も `gate1-spike`。

理由: 検証項目に `tmux set -g mouse on/off` と `set -g window-size ...` が含まれる。
`-g` はサーバ単位のグローバルオプションなので、既定サーバで撃つと
ユーザーの `digi-plus` / `k-pla` / `personal` セッションに波及してしまう。
別ソケットならユーザーの `~/.tmux.conf` は同じように読み込みつつ、影響が完全に閉じる。

検証後に `tmux -L gate1-spike kill-server` し、既定サーバのセッション一覧・
`mouse` / `window-size` / `prefix` が検証前と同一であることを確認済み。

> **検証中に 1 件汚染が発生し、その場で復旧した。**
> 外部ターミナル同時 attach のために `open -na /Applications/Ghostty.app` した際、
> `-e` で指定したウィンドウとは**別に**既定ウィンドウがもう 1 枚開き、
> そのシェルが既定サーバに新規セッション `4` を作っていた。
> 検証終了後に当該 Ghostty インスタンスを終了し `kill-session -t 4` して除去した。
> **申し送り:** `open -na` は余計なウィンドウを開く。今後は
> `ghostty -e ...` を直接起動するか、外部クライアントも別ソケット前提で扱うこと。

### 7.2 入力の自動化方法(および、その限界)

このマシンには `cliclick` が無く(新規インストールはしない方針)、Claude Code の
実行コンテキストにアクセシビリティ権限も無いため、**`CGEvent` / `System Events` による
物理的なキー・マウスの合成ができない**。

そこでアプリ内に制御チャネル(`SpikeControl.swift`)を足し、
**AppKit のイベント配送層をバイパスして libghostty の入力 API を直接叩いた。**

- 検証したいのは「AppKit がイベントを配れるか」(自明)ではなく、その先の
  「libghostty がキー / マウスをどうエンコードして PTY へ流し、tmux がどう解釈するか」なので、
  この省略で失われる情報は小さい。
- ただし **`NSEvent` → libghostty 引数への変換部分(`makeKeyEvent` /
  `reportMousePosition` / `scrollWheel` の実装)は検証されていない。** §8.9 に手動確認手順を書いた。

`SpikeControl.swift` は `GhosttyKit` を import していない。libghostty を呼ぶのは
`GhosttyTerminalView.swift` の `spike*` メソッドのみで、設計書 §21.5 の隔離境界は M2 でも保っている。

---

## 8. M2 の結果

環境: tmux 3.4 / ghostty v1.3.1 / macOS 26.5.2 arm64。
ユーザーの `~/.tmux.conf` をそのまま使用(**prefix は `C-q`**、`mouse on`、
`status-position top`、`default-terminal tmux-256color`、
`WheelUpPane` でcopy-mode 突入、`MouseDragEnd1Pane` で `pbcopy`)。

### 8.1 結果一覧

| # | 検証項目 | 結果 | 証跡 |
|---|---|---|---|
| 1 | `tmux new-session -A -s gate1-spike` で attach | ✅ | `m2-01-reattach.png` |
| 2 | クライアントの `TERM` が `xterm-ghostty` で通る | ✅ | §8.2 |
| 3 | ウィンドウリサイズ → tmux クライアントサイズ追随(SIGWINCH) | ✅ | §8.7 |
| 4 | detach(prefix+d)後もセッション・pane プロセスが生存 | ✅ | `m2-21-after-detach.png` |
| 5 | アプリ再起動 → 同一セッションへ再 attach、レイアウト・pane pid・scrollback 保持 | ✅ | `m2-22-reattach-after-detach.png` |
| 6 | **app から `tmux split-window -h/-v` (CLI) → 表示が即時追随** | ✅ | `m2-02`, `m2-03` |
| 7 | **app から `tmux resize-pane -Z` (CLI) → zoom 表示が即時追随** | ✅ | `m2-04-cli-zoom.png` |
| 8 | app から `tmux select-pane` (CLI) → active pane 表示が追随 | ✅ | §8.3 |
| 9 | app から `tmux send-keys` (CLI) → pane に反映 | ✅ | `m2-19` |
| 10 | キーバインド経由の prefix(`C-q`)が libghostty に食われない | ✅ | §8.4 |
| 11 | prefix + `z` で zoom / unzoom | ✅ | `m2-05-key-zoom.png` |
| 12 | prefix + `%` / `o`(既定 + ユーザー定義)で split | ✅ | `m2-06-key-splits.png` |
| 13 | prefix + `h`/`j`/`k`/`l` で pane 移動 | ✅ | §8.4 |
| 14 | prefix + `d` で detach | ✅ | `m2-21` |
| 15 | libghostty 自身の split / tab キーバインド(`cmd+d` / `cmd+t`)を握り潰せる | ✅ | §8.5 |
| 16 | mouse on: クリックで pane 選択 | ✅ | `m2-07-mouse-select-pane.png` |
| 17 | mouse on: pane 境界ドラッグでリサイズ | ✅ | `m2-09-mouse-pane-resize.png` |
| 18 | mouse on: ホイールで copy-mode 突入 / 復帰 | ✅ | `m2-08-mouse-scroll-copymode.png` |
| 19 | mouse on: 素のドラッグ → **tmux 側**の選択(app 側 selection は発生しない) | ✅ | `m2-10-selection-mouse-on.png` |
| 20 | mouse on + Shift ドラッグ → **libghostty 側**の選択(capture バイパス) | ✅ | `m2-11-selection-shift-drag.png` |
| 21 | mouse off → libghostty 側の選択・スクロールバック | ✅ | `m2-13-mouse-off-selection.png` |
| 22 | libghostty の選択が **pane 境界を無視する** | ⚠️ 仕様上の制約 | `m2-12-selection-cross-pane.png` |
| 23 | `cmd+C` で app 側 selection をクリップボードへ | ✅ | §8.6 |
| 24 | `cmd+V` で複数行・特殊文字・日本語を bracketed paste | ✅ | `m2-14-paste-multiline.png` |
| 25 | URL hit testing(hover → `MOUSE_OVER_LINK`、click → `OPEN_URL`) | ✅(条件付き) | `m2-15-url-hover.png` |
| 26 | OSC 8 ハイパーリンクが tmux 越しに届く | ✅ | `m2-23-truecolor-osc8.png` |
| 27 | パス(`/Users/...`)の hit testing | ⚠️ 部分的 | §8.6 |
| 28 | **mouse reporting ON のとき hover 検出が抑止される** | ⚠️ | §8.6 |
| 29 | 外部ターミナル(Ghostty.app)と同一セッションへ同時 attach | ✅ | §8.7 |
| 30 | サイズの奪い合い(`window-size` smallest / latest / largest) | ✅ 計測済み | `m2-16` `m2-17` `m2-18` |
| 31 | truecolor が tmux 越しに通る | ✅ | `m2-23` |
| 32 | `tmux send-keys -l` による複数行注入 | ❌ 改行で実行されてしまう | §8.8 |
| 33 | `tmux load-buffer` + `paste-buffer -p` による複数行注入 | ✅ | `m2-20-paste-buffer-injection.png` |
| 34 | Gate 3 前哨: tmux CLI から pane / client を特定できるか | ✅ | §8.10 |
| 35 | 物理キーボード / 物理マウス(AppKit `NSEvent` 経路) | **未検証(要手動確認)** | §8.9 |
| 36 | トラックパッドの慣性スクロール / 右クリック / コンテキストメニュー | **未検証(要手動確認)** | §8.9 |
| 37 | 描画のなめらかさ・カーソル点滅・フォント品質・体感遅延 | **未検証(要手動確認)** | §8.9 |

**撤退基準への抵触: なし。** PLAN.md §7-4「tmux attach 下で split / zoom / detach / mouse が壊れる」に
該当する事象は出なかった。⚠️ の 4 件はいずれも回避策があり、設計判断で吸収できる範囲。

### 8.2 attach / detach / 再 attach

- surface の `command` に `tmux -L gate1-spike new-session -A -s gate1-spike` を渡すだけで attach できる。
- tmux クライアントの `TERM` は **`xterm-ghostty`**(M1 で仕込んだバンドル内 terminfo が効いている)。
  pane 内の `TERM` はユーザー設定の `default-terminal` に従い `tmux-256color`。
  24bit color(`\033[38;2;...`)は tmux を越えて通る。
- **detach すると surface のプロセスが死ぬ。** `[detached (from session gate1-spike)]` の後に
  libghostty が `Process exited. Press any key to close the terminal.` を表示し、
  `ghostty_surface_process_exited()` が `true` になる。セッションと pane プロセスは生き続ける。
  → **v1.3.1 の `ghostty.h` には「同じ surface でコマンドを再実行する」API が無い。**
  本体で「detach 後に再 attach」を実現するには **surface を破棄して作り直す**か、
  `command` を `while true; do tmux attach ...; done` 相当のラッパーにする必要がある。
  Gate 1 の結論には影響しないが、タブのライフサイクル設計に効く。
- アプリを終了 → 再起動すると同一セッションへ再 attach でき、
  **pane レイアウト・`pane_pid`・scrollback がすべて保持される**(pid 97704 が detach 前後で不変)。

### 8.3 app からの tmux CLI 操作に対する表示追随(最重要)

設計書 §21.3 は「tmux を CLI で扱う」方針であり、**アプリが `tmux split-window` 等を
外部プロセスとして叩いたときに surface の表示が即座に追いつくか**が M2 の本命だった。

結論: **問題なし。**

- `tmux split-window -h` / `-v` / `resize-pane -Z` / `select-pane` / `send-keys` を
  シェルから実行した直後(0.3〜0.6 秒後)に撮ったスクリーンショットは、
  すべて既に新しい状態を描画していた。
- **ホスト側から `ghostty_surface_refresh` / `ghostty_surface_draw` を呼ぶ必要はない。**
  tmux が PTY へ再描画シーケンスを流し、libghostty が自走して描く。
  M1 の所見(「描画は libghostty が自走する」)が tmux 越しでもそのまま成り立つ。
- したがって本体の操作 API(split / close / select / zoom)は
  **「tmux CLI を叩くだけ」で実装できる見込み。** 表示同期のための追加機構は要らない。

### 8.4 キーバインド衝突

| 送ったキー | libghostty が消費したか | tmux に届いたか |
|---|---|---|
| `ctrl+q`(ユーザーの prefix) | 消費(= PTY へエンコードして送出) | ✅ `client_key_table=prefix` になる |
| prefix → `z` | 同上 | ✅ zoom / unzoom |
| prefix → `%` / `o` / `p` | 同上 | ✅ split |
| prefix → `h` / `j` / `k` / `l` | 同上 | ✅ pane 移動 |
| prefix → `d` | 同上 | ✅ detach |
| `cmd+d` / `cmd+t` / `cmd+shift+d` | **キーバインドとして消費、PTY へは流れない** | ❌(届かない。意図どおり) |

**衝突は 1 件も無かった。** libghostty の既定キーバインドは macOS 流に `cmd` 起点であり、
tmux の prefix(`C-q` や既定の `C-b`)や copy-mode のキーとは重ならない。

> **注意(用語):** `ghostty_surface_key()` の戻り値 `true` は「キーバインドに食われた」ではなく
> 「libghostty が処理した(PTY へ送った場合も含む)」という意味である
> (`src/apprt/embedded.zig` → `app.keyEvent`)。
> 「バインドに一致するか」を事前に知りたい場合は `ghostty_surface_key_is_binding()` を使う。

### 8.5 libghostty 側 split の握り潰し(PLAN.md §6.1 の結論)

`cmd+d` / `cmd+t` を送ると `GHOSTTY_ACTION_NEW_SPLIT`(tag=4)/ `NEW_TAB`(tag=2)が
action callback に飛んでくる。M1 で仕込んだ「`false` を返す」実装で

- ホスト側は何もしない
- **キー自体は libghostty に消費され、PTY へは流れない**(tmux の pane 数は不変)

という挙動になった。設計書 §4.1(確定、pane 分割は tmux の責務)と矛盾しない形で
握り潰せることが実証できた。**PLAN.md §6.1 は解決。**

### 8.6 copy / paste / selection / URL の整理

**選択の二重管理は「mouse reporting の ON/OFF」で綺麗に分かれる。**

| tmux `mouse` | 修飾キー | 選択の主体 | app 側 `has_selection` | 結果 |
|---|---|---|---|---|
| on | なし | **tmux copy-mode** | `false` | ユーザー設定の `MouseDragEnd1Pane` が `pbcopy` まで実行 |
| on | **Shift** | **libghostty** | `true` | grid ベースの選択。`cmd+C` で `NSPasteboard` へ |
| off | なし | **libghostty** | `true` | 同上。クリックしても tmux の active pane は変わらない |

- `ghostty_surface_mouse_captured()` が `mouse on` / `off` にそのまま追随する(`true` / `false`)。
  **本体はこれを見て「今どちらが選択の主体か」を UI に出せる。**
- ⚠️ **libghostty の選択は pane 境界を知らない。** 2 pane をまたいで Shift ドラッグすると
  `"SELECTME-ABCDEFGH                            │RIGHTPANE-XYZ"` のように
  **tmux の pane 区切り `│` と隣の pane のテキストごと**取れる(`m2-12`)。
  「pane 単位で正しくコピーしたい」なら tmux の copy-mode に任せるしかない。
- paste は `cmd+V` で `read_clipboard_cb` → bracketed paste として PTY へ。
  複数行・`"quote"`・`$VAR`・`` `backtick` ``・`% & | ;`・日本語すべてそのまま入り、
  **改行があってもコマンドは実行されない**(fish が複数行入力として扱う)。
- **URL / path hit testing は動くが条件がある。**
  - ghostty の既定リンク設定は `highlight = hover_mods(ctrlOrSuper)`、つまり
    **macOS では ⌘ を押しながら hover しないと検出されない**(`src/config/Config.zig`)。
  - さらに `Surface.zig` の条件により、**mouse reporting が ON の間は hover 検出が抑止される。**
    実測:
    | 状態 | 結果 |
    |---|---|
    | mouse on + ⌘ hover | ❌ 検出されない |
    | mouse on + Shift+⌘ hover | ✅ 検出される(Shift が capture を外すため) |
    | mouse off + ⌘ hover | ✅ 検出される |
  - ⌘+クリックで `GHOSTTY_ACTION_OPEN_URL` が飛ぶ(スパイクでは開かずログのみ)。
  - **OSC 8 ハイパーリンクは tmux を越えて届く**(`MOUSE_OVER_LINK url=https://example.com/osc8`)。
  - ⚠️ パスも既定の URL 正規表現に一致して検出されるが、
    **tmux の pane 幅で折り返された行はそこで切れる**。
    45 桁 pane で `/Users/odaryo/workspace/sample/agent-workflow-terminal/README.md` を出すと
    `/Users/odaryo/workspace/sample/agent-workflow` までしか取れなかった。
    tmux は pane 内の折り返しを外側ターミナルから見ると「別の行」として書くため、
    libghostty の soft-wrap 追跡が効かない。**Viewer Drawer へのパス連携を作るなら、
    リンク検出は libghostty ではなく tmux の `capture-pane` 側でやるほうが堅い。**

### 8.7 複数クライアント同時 attach とサイズの奪い合い

スパイクアプリ(137x39)と `Ghostty.app`(199x56)を同一セッションへ同時 attach した。
両方 `TERM=xterm-ghostty`。入力の排他は無く、両方から同時に打てる(設計書 §4.2 確定の想定どおり)。

| `window-size` | tmux window サイズ | スパイク側の見え方 |
|---|---|---|
| `smallest` | **79x20**(スパイクを 640x400 に縮めた時) | 全部見える。大きい方(Ghostty)が余白だらけになる |
| `latest` (**tmux 3.4 の既定**) | 最後に操作したクライアントのサイズ | 操作するたびに 79x20 ↔ 199x55 と切り替わる |
| `largest` | **199x55** | ⚠️ **はみ出す。** ステータス行に `[0,12]` のオフセット表示が出て、右下が見えない(`m2-18`) |

- ウィンドウリサイズ(`resize 640 400`)は SIGWINCH としてすぐ tmux クライアントへ伝わる
  (137x39 → 79x21)。libghostty 側の PTY サイズ通知は正しく動いている。
- **申し送り:** iPhone/iPad から同じ session に attach する構成(設計書 §4.2 / Gate 2)では
  この 3 択が体験を大きく左右する。既定の `latest` は「小さい端末で 1 回触ると Mac 側が
  その場で縮む」挙動になる。**どの `window-size` を採るかは設計判断事項**(本スパイクでは決めない)。

### 8.8 pane へのテキスト注入(PLAN.md §6.2 の結論)

M1 の申し送りどおり、**ホストから PTY へ生バイトを書く API は v1.3.1 に無い。**
加えて M2 で分かったこと:

> **`ghostty_surface_text()` は打鍵ではなく「paste」である。**
> `Surface.textCallback` → `completeClipboardPaste()` を通り、bracketed paste で包まれる
> (`src/Surface.zig`)。つまり「ユーザーが打った」ことにはできない。
> tmux の prefix 待ち状態で `ghostty_surface_text("z")` を送っても
> `ESC[200~z ESC[201~` になり、キーバインドは発火しない(実測)。
> 打鍵として送るには `ghostty_input_key_s.text` に「その打鍵が生成する文字」を入れて
> `ghostty_surface_key()` を呼ぶ必要がある(AppKit の `event.characters` 相当)。

注入手段の比較(実測):

| 手段 | 複数行 | 特殊文字 / 日本語 | 勝手に実行されるか |
|---|---|---|---|
| `tmux send-keys -l '<text>'` | ⚠️ | ✅ | ❌ **改行がそのまま Enter になり、1 行目が実行された** |
| `tmux load-buffer` + `paste-buffer -p` | ✅ | ✅ | ✅ されない(bracketed paste) |
| `ghostty_surface_text()`(= paste 経路) | ✅ | ✅ | ✅ されない |

→ **`tmux load-buffer` + `paste-buffer -p` が本命。** 設計書 §9.2「Diff review コメントを
実装 agent の pane へ送る」/ §10「Ask Agent」は、この経路で実現できる見込み。
`tmux send-keys -l` は 1 行テキスト専用と割り切るか、改行を明示的に `Enter` として送る形にする。
**方式の決定は本スパイクでは行わない。**

### 8.9 未検証(手動確認が必要な項目)

自動化の都合上、**AppKit の `NSEvent` を libghostty 引数へ変換する部分**と
**主観的な描画品質**は検証できていない。以下を手で確認してほしい。

```shell
# 1. 起動
Spikes/gate1/scripts/build-ghostty.sh          # 未ビルドなら
Spikes/gate1/scripts/build-app.sh
tmux -L gate1-spike kill-server 2>/dev/null
TERMINAL_SPIKE_COMMAND='tmux -L gate1-spike new-session -A -s gate1-spike' \
  Spikes/gate1/build/TerminalSpike.app/Contents/MacOS/TerminalSpike
```

確認項目:

1. **物理キーボード** — 実際に `C-q`(prefix)→ `%` / `z` / `d` を打つ。
   `keyDown` / `flagsChanged` の実装(`GhosttyTerminalView.swift`)が正しく
   keycode・左右修飾キー・`characters(byApplyingModifiers:)` を渡せているか。
   矢印キー、`Ctrl-C`、`Ctrl-D`、`Esc`、リピート入力(押しっぱなし)も。
2. **物理マウス / トラックパッド** — pane クリック選択、pane 境界ドラッグでのリサイズ、
   2 本指スクロール(**慣性スクロールの `momentumPhase` 処理**は自動検証で通っていない)、
   ドラッグ選択、右クリック。
3. **描画品質** — カーソル点滅、スクロールのなめらかさ、フォントのにじみ、
   色再現。**本家 `Ghostty.app` を隣に並べて見比べること**(同一マシンで比較できる)。
4. **体感遅延** — キーを打ってから文字が出るまで。`Ghostty.app` との差。
5. **リサイズ中の追随** — ウィンドウをドラッグでぐりぐり広げ縮めした時に
   tmux の再描画が破綻しないか。
6. **外部ディスプレイ** — 別解像度のディスプレイへウィンドウを移動(M1 から継続の未検証項目)。

終了後は必ず `tmux -L gate1-spike kill-server` すること。

### 8.10 Gate 3(Agent Adapter)への申し送り

M1 の申し送り「v1.3.1 に `ghostty_surface_foreground_pid` / `tty_name` が無い」を前提に、
tmux CLI 側で何が取れるかを実測した。**十分に取れる。**

```
$ tmux -L gate1-spike list-panes -a -F '...'
pane=gate1-spike:0.0 id=%0 pid=97704 tty=/dev/ttys010 cmd=fish \
  path=/Users/odaryo/workspace/sample/agent-workflow-terminal/Spikes/gate1 \
  title=~/w/s/a/S/gate1 dead=0

$ tmux -L gate1-spike list-clients -F '...'
name=/dev/ttys006 tty=/dev/ttys006 pid=2501 term=xterm-ghostty size=137x39 activity=1788168362
```

- `#{pane_pid}` / `#{pane_tty}` / `#{pane_current_command}` / `#{pane_current_path}` /
  `#{pane_title}` / `#{pane_dead}` がすべて取れる。
  **Agent の状態推定に必要なプロセス情報は tmux 側で完結する。**
- `#{client_pid}` / `#{client_activity}` も取れるので、
  「どのクライアントがいつ触ったか」も観測できる(Gate 2 のマルチデバイス時に有用)。
- surface 側から取れるのは `ghostty_surface_process_exited()` のみ。
  → **`AgentAdapter` は libghostty ではなく tmux CLI をプロセス観測の一次情報源にする**、
  という前提で設計してよい。これは設計書 §21.3(tmux を CLI で扱う)とも整合する。

### 8.11 M2 で見つかったスパイク側の不具合(修正済み)

- M1 の `TerminalSpikeApp.swift` は `.ignoresSafeArea()` を付けており、
  ターミナル面がタイトルバーの下へ潜り込んで**先頭行が見えなくなっていた**。
  ユーザー環境の tmux は `status-position top` なので、ステータス行がまるごと隠れていた。
  M2 で除去した。**本体でもタイトルバー / ツールバーとターミナル面の重なりは要注意。**

---

## 9. M3 の進め方(実際に採った方法)

### 9.1 M2 の隔離方式をそのまま再利用

専用 tmux サーバソケット `-L gate1-spike` + セッション `gate1-spike`、および
`TERMINAL_SPIKE_CONTROL` 制御チャネル(§7.2)を M3 でもそのまま使った。
`scripts/m3-harness.sh` は `m2-harness.sh` に委譲する薄いラッパで、証跡の接頭辞だけ
`m3` に切り替える(`SPIKE_SHOT_PREFIX`)。M3 で足したサブコマンドは 3 つだけ:

```shell
Spikes/gate1/scripts/m3-harness.sh launch 1400x900       # tmux attach で起動
Spikes/gate1/scripts/m3-harness.sh launch-bare 1400x900  # tmux を挟まず bash 直起動
Spikes/gate1/scripts/m3-harness.sh tmux <args...>        # gate1-spike サーバへ tmux コマンド
echo 'cmd' | Spikes/gate1/scripts/m3-harness.sh run      # paste-buffer -p して Enter
Spikes/gate1/scripts/m3-harness.sh inject <file>         # ファイルを pane へ貼り付け
```

- `run` / `inject` は M2 §8.8 の結論どおり **`load-buffer` + `paste-buffer -p`** を使う。
- **`launch-bare` が M3 の切り分けの要**。同じテキストを「tmux 経由」と「tmux 無し」で
  出力させると、grapheme の扱いが tmux 側か libghostty 側かを一発で判定できる(§10.3)。

pane 内で実行する検証スクリプトは `scripts/m3-checks/` に置いてある(再現用)。

```shell
Spikes/gate1/scripts/m3-harness.sh launch 1400x900
echo 'bash Spikes/gate1/scripts/m3-checks/vt-color.sh' | Spikes/gate1/scripts/m3-harness.sh run
Spikes/gate1/scripts/m3-harness.sh shot 01-vt-color
```

エージェント起動は **scratchpad 配下の空ディレクトリ**で行い、本リポジトリ内では起動していない
(エージェントがリポジトリを読み始めるのを防ぐため)。プロンプトは日本語 1 回 (`1+1は? 短く答えて`) のみ。
検証後、スパイクアプリ・`claude` / `codex` プロセス・`gate1-spike` サーバ・作業ディレクトリは全て破棄し、
**ユーザーの既定 tmux サーバのセッション一覧・`mouse` / `window-size` / `prefix` が検証前と同一である**
ことを確認済み。`open -na Ghostty` は M2 の教訓どおり一度も使っていない。

### 9.2 M3 でスパイク側に足したもの

| 追加物 | 場所 | 目的 |
|---|---|---|
| **`NSTextInputClient` 準拠** | `GhosttyTerminalView.swift` | M1 / M2 で未実装だった IME 経路。`setMarkedText` → `ghostty_surface_preedit`、`firstRect(forCharacterRange:)` → `ghostty_surface_ime_point` |
| `keyDown` の書き換え | 同上 | `interpretKeyEvents` を通し、`insertText` が積んだ確定文字列を打鍵として送る。変換中は `ghostty_input_key_s.composing = true` にして端末へエンコードさせない |
| `doCommand(by:)` の握り潰し | 同上 | 端末アプリで AppKit の編集コマンド (`insertNewline:` 等) を実行させない。通常の打鍵経路 (`ghosttyText(for:)`) に任せる |
| `preedit` / `ime` / `keydown` コマンド | `SpikeControl.swift` | 実 IME 無しで preedit 描画と `ime_point` を確認する。`keydown` は **合成 `NSEvent` を `keyDown(with:)` に流す**(書き換えた keyDown 経路の回帰確認) |

libghostty を呼ぶのは引き続き `GhosttyTerminalView.swift` だけで、§21.5 の隔離境界は M3 でも保っている。
`TerminalRenderer` 候補として `setPreedit` / `imePoint` の 2 つが増えた(`// [RENDERER]` 印)。

### 9.3 ディスプレイスリープの罠(M3 で最初に踏んだ)

**ディスプレイがスリープしていると `ghostty_surface_new` が失敗する。**

```
[com.apple.corevideo] CVDisplayLinkCreateWithCGDisplays error -6661 due to invalid display count (0)
[com.mitchellh.ghostty:embedded_window] embedded_window: error initializing surface err=error.OutOfMemory
```

- 検証時のこのマシンは `displaysleep 2` / `sleep 1`(バッテリー)で、放置すると即ディスプレイが落ちる。
  その状態では **surface が作れず、`screencapture -l <winid>` も空振りする**。
- 対策として `m3-harness.sh` の `launch` / `shot` は毎回 `caffeinate -u -t 30` を**新規に**起動して
  「今ユーザー操作があった」と宣言し直す(既に走っている caffeinate では寝たディスプレイは起きない)。
  `shot` は撮れるまで最大 3 回リトライする。
- **申し送り(本体設計):** libghostty の surface 生成はアクティブなディスプレイに依存する。
  「Mac のフタを閉じた / ディスプレイスリープ中でもエージェントを走らせ続ける」という本製品の
  想定運用(§4.2 のマルチデバイス、iPhone から attach)では、**Mac 側 UI の surface が作れない / 描けない
  局面がありうる**。エージェント本体は tmux 側で走り続けるので実害は「Mac の画面が使えない間だけ」だが、
  Host Core が surface 生成に失敗したときのフォールバック(遅延生成・リトライ)は設計に要る。

---

## 10. M3 の結果

環境: tmux 3.4 / ghostty v1.3.1 / macOS 26.5.2 arm64 / Claude Code 2.1.251 / Codex CLI 0.147.0。
ユーザーの `~/.tmux.conf` をそのまま使用(prefix `C-q`、`mouse on`、`status-position top`、
`default-terminal tmux-256color`)。pane 内の shell は fish。

### 10.1 結果一覧

| # | 検証項目 | 結果 | 証跡 |
|---|---|---|---|
| 1 | ANSI 16 / 256色 / grayscale / truecolor(24bit) | ✅ `COLORTERM=truecolor` で 24bit が通る | `m3-01-vt-color.png` |
| 2 | SGR: bold / dim / italic / underline / curly / 下線色(SGR58) / blink / reverse / strike / double-underline | ✅ 全て描き分けられる | `m3-01` |
| 3 | box drawing(`┌─┬┐ │ └┴┘ ╚═╩╝ █▓▒░ ▲▼◀▶`)、braille | ✅ セル境界で罫線が繋がる(欠けなし) | `m3-01` |
| 4 | スクロールリージョン(DECSTBM) | ✅ 固定行が動かず、指定範囲だけスクロールする | `m3-02-scroll-region-during.png` |
| 5 | alternate screen 出入り(`less`) | ✅ 入り / 移動 / `q` で元画面に復帰 | `m3-03` / `m3-04` / `m3-05` |
| 6 | alternate screen 出入り(`vim`) | ✅ 全画面 TUI + ステータス行、`:q!` で復帰 | `m3-06` / `m3-07` |
| 7 | `vttest` | ⏭️ **未導入のためスキップ**(新規インストールしない方針)。代替として 1〜6 を自動化して確認 | — |
| 8 | 日本語(ひらがな / 漢字 / カタカナ / 全角英数 / 約物)の全角幅 | ✅ 桁定規と一致 | `m3-08-wide-text.png` |
| 9 | East Asian Ambiguous(`± ○ △ × ※ ¶ § °`) | ✅ = **半角(幅1)扱い**。tmux 有無で差なし | `m3-08` / `m3-11` |
| 10 | 絵文字(単一 codepoint / VS16 / VS15 / 肌色修飾 / 国旗) | ✅ 幅・字形とも正しい。VS15 は白黒字形、VS16 は絵文字字形で描き分け | `m3-08` / `m3-11` |
| 11 | ZWJ シーケンス | ⚠️ **tmux 経由でのみ 👨‍👩‍👧‍👦 が 4 セルに割れる**(libghostty 単体では 2 セル正解)。詳細 §10.3 | `m3-09` / `m3-10` / `m3-11` |
| 12 | 日本語ファイル名の `ls` / `ls -la` の桁揃え | ✅ 崩れなし | `m3-12-ls-japanese-filenames.png` |
| 13 | tmux ステータス行 / window 名の日本語・絵文字 | ✅ 日本語は正常。⚠️ ZWJ を含めると tmux が消し残す(§10.3) | `m3-12` / `m3-13` |
| 14 | pane 分割時の全角文字の欠け・境界越え | ✅ 境界での欠け・にじみ無し。折り返しも全角境界を割らない | `m3-13-split-japanese-boundary.png` |
| 15 | リサイズ時の再折り返し(日本語) | ✅ 破綻なし | `m3-14` / `m3-15` |
| 16 | Claude Code 起動画面・ロゴ・罫線 | ✅ 半ブロック文字のロゴ・区切り線・入力枠すべて正常 | `m3-17-claude-ready.png` |
| 17 | Claude Code の権限確認プロンプト(フォルダ信頼) | ✅ 選択肢・`❯` カーソル・注意文が読める(設計書 §11 の前提を満たす) | `m3-16-claude-launch.png` |
| 18 | Claude Code の日本語入力表示 / 応答 / 進捗バー | ✅ composer の日本語も桁ずれ無し。`ctx ▍░░` 系のバーも正常 | `m3-18` / `m3-19` / `m3-20` |
| 19 | Claude Code の pane split / リサイズ再レイアウト | ✅ 87 桁・narrow へ即時再レイアウト。ゴミ残りなし | `m3-21` / `m3-22` / `m3-23` |
| 20 | Codex TUI 起動 / 角丸罫線ボックス / OSC8 リンク | ✅ `╭─╮ │ ╰─╯` が繋がる。リンクは下線付き | `m3-25` / `m3-26` / `m3-27` |
| 21 | Codex の日本語入力 / 応答 | ✅ 認証済みで実応答まで確認(`2です。`) | `m3-28` / `m3-30` |
| 22 | Codex の pane split / リサイズ再レイアウト | ✅ ボックス幅が追随。崩れなし | `m3-31` / `m3-32` / `m3-33` |
| 23 | エージェント終了(`/exit` / `/quit`)後の画面復帰 | ✅ 両者とも元画面に戻る | `m3-24` / `m3-34` |
| 24 | preedit(変換中文字列)の描画 | ✅ **下線付きで正しく描画される**。全角幅も正しい | `m3-35-ime-preedit.png` / `m3-37` |
| 25 | `ghostty_surface_ime_point`(候補ウィンドウ位置) | ✅ 端末カーソルに追随。⚠️ width のスケール規約に難あり(§10.6) | ログ(§10.6) |
| 26 | 書き換えた `keyDown` 経路(合成 `NSEvent` → `interpretKeyEvents`) | ✅ ASCII / 日本語 / Enter が期待どおり pane へ届く | `m3-37-keydown-and-preedit.png` |
| 27 | **実 IME(かな漢字変換)の操作** | ❓ **未検証(要手動確認)**。プログラムから入力ソースを切り替えられないため。手順は §10.8 | — |

### 10.2 VT互換性(§24「VT互換性」)

`vttest` はこのマシンに無く、方針上インストールしないので、**自動化できる範囲で代替した**。
色・SGR・box drawing・DECSTBM・alternate screen という「TUI が実際に使う経路」は全て通っている。
`m3-01-vt-color.png` を拡大すると、`┌─┬─┐` `╚═╩═╝` がセルをまたいで**隙間なく連結**しており、
libghostty が box drawing グリフを合成描画していることが分かる(フォント依存の切れ目が出ない)。

未確認:
- `vttest` の網羅項目(DECALN、DECCOLM、各種 CSI のエッジケース、二重高さ文字など)。
- **これは Gate 1 の合否を左右しないと判断した**。Agent Terminal で動かす対象は
  Claude Code / Codex / less / vim / git であり、その全てが実動している。

### 10.3 日本語・絵文字・grapheme width(§24「絵文字・grapheme width」)

DSR(CPR, `ESC[6n`)で「文字列を出力した直後のカーソル桁」を実測した。
**同じスクリプトを `launch`(tmux 経由)と `launch-bare`(tmux 無し)の両方で走らせて切り分けた。**

| 入力 | 期待 | tmux 経由 | tmux 無し(= libghostty 単体) |
|---|---|---|---|
| `abcdef` | 6 | 6 ✅ | 6 ✅ |
| `あいう` | 6 | 6 ✅ | 6 ✅ |
| `漢字混在` | 8 | 8 ✅ | 8 ✅ |
| `ＡＢＣ`(全角英字) | 6 | 6 ✅ | 6 ✅ |
| `±○△×`(Ambiguous) | 4(narrow 前提) | 4 ✅ | 4 ✅ |
| `😀🍣` | 4 | 4 ✅ | 4 ✅ |
| **`👨‍👩‍👧‍👦`(ZWJ×3、4人家族)** | 2 | **4 ❌** | **2 ✅** |
| `👩‍💻`(ZWJ×1) | 2 | 2 ✅ | 2 ✅ |
| `👍🏽`(肌色修飾) | 2 | 2 ✅ | 2 ✅ |
| `🇯🇵`(国旗 = RIS ペア) | 2 | 2 ✅ | 2 ✅ |
| `❤️`(VS16) | 2 | 2 ✅ | 2 ✅ |
| `❤︎`(VS15) | 1 | 1 ✅ | 1 ✅ |
| `é`(結合文字) | 1 | 1 ✅ | 1 ✅ |
| `한국어` | 6 | 6 ✅ | 6 ✅ |

**結論: grapheme width の不一致は 1 件だけで、原因は tmux 3.4 側。libghostty は 14/14 正解。**

- 目視でも一致する。tmux 経由の `m3-08` では ZWJ 行が
  `👨‍👩‍👧‍👦` `👩` `👩‍💻` `Ă` `🌈` のように**割れて**表示され、
  tmux 無しの `m3-11` では `👨‍👩‍👧‍👦` `👩‍💻` `🏳️‍🌈` が**それぞれ 1 グリフ**として出る。
- 副作用として、ZWJ を `status-right` に入れると **tmux が幅を読み違えて右端に消し残しが出る**
  (`m3-13` の `... 👨‍👩‍👧‍👦 19:19 26` の `26` は前の内容の残骸)。
- **これは「埋め込み方の問題」でも「libghostty の問題」でもなく、tmux の問題**。
  tmux は 3.5 以降 grapheme 対応が改善しているので、**本体では tmux の下限版数を検討する余地がある**
  (本スパイクでは決めない)。実害は「4人家族絵文字とその類が 2 セル余分に見える」程度。
- 補足: `ls` が `絵文字👨‍👩‍👧‍👦テスト.txt` を `絵文字👨?👩?👧?👦テスト.txt` と出すのは **BSD `ls` が ZWJ を
  非表示文字として `?` に置換している**ためで、端末側の問題ではない(`printf` では正しく出る)。

その他の所見:

- **East Asian Ambiguous は幅 1**(`± ○ △ ×` など)。日本語環境では「全角で見たい」ユーザーが居るが、
  v1.3.1 の libghostty にこれを切り替える設定は見当たらない。**本体で設定を出すなら要調査**(申し送り)。
- ハングルは幅こそ正しい(2セル)が、**グリフが 2 セル幅より細く描かれる**(フォントフォールバックの見た目差)。
  桁ずれは起きないので実害なし。
- 全角の折り返し・pane 境界での欠けは**一切無し**(`m3-13` / `m3-14`)。

### 10.4 Claude Code TUI(撤退基準 §7-2 の対象)

- 起動画面の半ブロック文字ロゴ(`▐▛███▛█` 等)が**ドット絵として正しく組み上がる**。
  ここが崩れる端末は多いので、良い指標になる。
- **権限確認プロンプト**(フォルダ信頼の Yes/No 選択)が問題なく読める(`m3-16`)。
  設計書 §11「質問 UI」は、この見た目を前提にできる。
- 日本語プロンプトの composer 表示、確定後のユーザー発話ハイライト帯、
  応答(`⏺ 2`)、スピナー(`✻ Sautéed for 3s`)、`ctx ▍░░░░░░░░░ 4%` 形式のバーまで全て正常。
- `tmux split-window -h` で 174桁 → 87桁になった瞬間に**再レイアウトされ、パスが `/…/` で省略される**。
  ウィンドウリサイズ(820x560 まで縮小)でも同様。ゴミ・二重描画は観測されなかった。
- `/exit` で通常終了し、pane は fish に戻る。

**表示崩れ・入力取りこぼしは観測されなかった。**

### 10.5 Codex TUI

- 角丸ボックス(`╭ ─ ╮ │ ╰ ╯`)が連結して描かれる。OSC 8 ハイパーリンクも下線付きで出る。
- 起動時の 2 段の対話(アップデート案内 / ディレクトリ信頼)はどちらも選択肢が正しく描かれ、
  数字キーで選択できた。
- 認証済みだったので **実応答まで確認できた**(日本語プロンプト → `2です。`)。
  PLAN.md が想定していた「認証で進めない場合は起動画面だけ」には**該当しなかった**。
- split / リサイズでボックス幅が追随し、崩れない。`/quit` で通常終了。

→ **§12「Agent 非依存」の観点で、両エージェントとも同等に動くことを確認した。**

### 10.6 IME(撤退基準 §7-3 の対象)

**M1 / M2 で未実装だった IME 経路を M3 で実装した。** その上で、自動化できる範囲を実測した。

判明したこと:

1. `ghostty_surface_preedit(surface, utf8, len)` に変換中文字列を渡すと、
   **libghostty が下線付きでカーソル位置に描画する**(`m3-35` / `m3-37`)。
   全角文字の幅も正しく、確定前後で端末側の文字が壊れることもない。クリアは `(nil, 0)`。
2. `ghostty_surface_ime_point(surface, &x, &y, &w, &h)` は候補ウィンドウを出すべき矩形を返し、
   **端末カーソルに追随する**(fish のプロンプト 2 桁目 → `x=22.0pt`、cell幅 8.0pt)。
3. ⚠️ **`ime_point` の width だけスケール規約が違う。** `x` / `y` / `height` は content scale で割られて
   pt で返るが、**`width` は割られない**(`にほんご` = 8セル → 期待 64pt に対し `128.0` が返る)。
   upstream `src/Surface.zig` に
   「we don't apply content scale here because it looks like for some reason in macOS its already scaled」
   というコメントがあり、**upstream 自身が未整理と認めている箇所**。
   Retina では候補ウィンドウ矩形の幅が 2 倍になる。実害は候補パネルの位置決めだけなので、
   **ホスト側で `/ backingScaleFactor` する回避が必要**(本スパイクでは補正していない。生値を記録する方針)。
   → **`TerminalRenderer` の `imePoint` は「libghostty の座標規約を吸収する」責務を持つ**、という
   §21.5 の具体例が 1 つ増えた。
4. 書き換えた `keyDown`(`interpretKeyEvents` → `NSTextInputClient` → accumulator)は、
   **合成 `NSEvent` を流す回帰テストで期待どおり動いた**(`echo keyDown経路OK 12345` が実行される)。
   Enter は `doCommand(by: insertNewline:)` に落ちて握り潰され、通常経路で `\r` として送られる。

**未検証(重要):** 実際のかな漢字変換操作。macOS の入力ソースはプログラムから切り替えられず、
このマシンにはアクセシビリティ権限も無いため、**「変換候補ウィンドウが正しい位置に出るか」
「変換中の Enter / Esc が端末へ漏れないか」「確定文字列が二重に入らないか」は人手で確認する必要がある。**
手順は §10.8。

**撤退基準 §7-3 との関係:** 「preedit が出ない」「候補ウィンドウ位置が取れない」という
**致命ケースは否定された**(API は存在し、実際に描画・取得できた)。
残るのは実操作の品質確認であり、現時点で Gate 1 不成立と判断する材料は無い。

### 10.7 撤退基準(PLAN.md §7)への当てはめ

| # | 撤退基準 | M3 時点の判定 |
|---|---|---|
| 2 | Claude Code / Codex の TUI が実用にならない | **抵触なし。** 両者とも表示崩れ・入力取りこぼし無し。権限プロンプトも読める |
| 3 | 日本語 IME が実用にならない | **抵触なし(ただし条件付き)。** preedit 描画と `ime_point` は動作。実変換操作は未検証 |
| 4 | tmux attach 下で split / zoom / detach / mouse が壊れる | M2 で抵触なし。M3 でも TUI 稼働中の split / resize が正常 |
| 6〜9 | 重大(条件付き) | M4 の対象。M3 の範囲では新たな抵触なし |

新たに見つかった**条件付きの論点**(致命ではない):

- **ディスプレイスリープ中は surface を作れない**(§9.3)。フォールバック設計が要る。
- **tmux 3.4 の ZWJ grapheme 幅**(§10.3)。tmux の下限版数を検討する余地。
- **`ime_point` の width スケール**(§10.6)。ホスト側で吸収する。

### 10.8 未検証(手動確認が必要な項目)

M2 §8.9 の項目に加えて、**IME の実操作**が残っている。以下を人手で確認してほしい。

```shell
Spikes/gate1/scripts/build-ghostty.sh          # 未ビルドなら
Spikes/gate1/scripts/build-app.sh
tmux -L gate1-spike kill-server 2>/dev/null
TERMINAL_SPIKE_COMMAND='tmux -L gate1-spike new-session -A -s gate1-spike' \
  Spikes/gate1/build/TerminalSpike.app/Contents/MacOS/TerminalSpike
```

確認項目(IME):

1. **入力ソースを「日本語 - ローマ字入力」に切り替えて `あいうえお` と打つ。**
   - 変換中に**下線付きの preedit** が出るか(自動検証では `preedit` コマンド経由でのみ確認済み)。
   - **変換候補ウィンドウがカーソルの真下に出るか**(`ime_point` の width スケール問題により、
     候補パネルの幅方向がずれる可能性がある)。
2. **変換中の Enter / Esc** — Enter で確定したときに端末へ改行が漏れないか、
   Esc で変換を取り消したときに端末側の文字が消えないか(`composing` フラグの効き)。
3. **確定文字列が二重に入らないか**(accumulator 経路と `ghosttyText(for:)` 経路の二重送信)。
4. **変換中に Backspace** — preedit だけが縮み、確定済みの文字が消えないか。
5. **Claude Code の composer に日本語を IME で直接打ち込む** — 上記が TUI 側でも成立するか。
6. **他の入力方式**(かな入力、ライブ変換 ON、Google 日本語入力等のサードパーティ IME)。
7. **絵文字ビューア(⌃⌘Space)からの挿入** — `keyDown` の外から `insertText` が来る経路
   (現在は paste 経路にフォールバックしている)。

確認項目(M2 から継続): 物理キーボード / 物理マウス / 描画品質 / 体感遅延 / リサイズ中の追随 /
外部ディスプレイ。M2 §8.9 を参照。

**終了後は必ず `tmux -L gate1-spike kill-server` すること。**

### 10.9 本体設計 / 後続 Gate への申し送り(M3 分)

1. **`TerminalRenderer` に `setPreedit` / `imePoint` が要る。** `imePoint` は libghostty の
   座標規約(左上原点・width だけ未スケール)を吸収する責務を持つ。
2. **`NSTextInputClient` は AppKit bridge の必須要素**(§5.1 の一覧に追加すべき項目)。
   SwiftUI だけでは日本語入力が成立しない。
3. **tmux の版数が grapheme 表示に効く。** ZWJ を含むブランチ名 / worktree 名 / エージェント出力は
   tmux 3.4 で幅が狂う。UI 側で「tmux が壊す前提」の逃げは作れないので、
   **サポートする tmux の下限版数を決める必要がある**(未確定事項として起票)。
4. **ディスプレイスリープ / ヘッドレス時の surface 生成失敗**に対する扱いを決める必要がある。
   エージェント自体は tmux 側で走り続けるので、**UI が作れないことと作業が止まることは別**である、
   という設計上の分離がここでも効く。
5. **エージェントの TUI は「pane 幅が変わると自分で再レイアウトする」** ことが両者で確認できた。
   Viewer Drawer の開閉(= pane 幅の変更)を tmux 側のリサイズで実現しても、エージェント側は追随する。

---

## 11. M4 の進め方(実際に採った方法)

### 11.1 M2 / M3 の隔離方式をそのまま再利用

専用 tmux サーバソケット `-L gate1-spike` + セッション `gate1-spike`、`TERMINAL_SPIKE_CONTROL`
制御チャネル、`load-buffer` + `paste-buffer -p` によるテキスト注入、`launch-bare`(tmux を挟まない
比較用の起動)をそのまま使った。`scripts/m4-harness.sh` は `m3-harness.sh` に委譲する薄いラッパで、
M4 で足したのは**計測系のコマンド(`ping` / `mem` / `sampler` / `soak-sampler` / `footprint`)だけ**である。
tmux サーバ単体のメモリ測定(§12.5)にだけ、アプリを介さない別ソケット `-L gate1-hist` を一時的に使った。

```shell
export M2_RUN_DIR=/tmp/gate1-m2
Spikes/gate1/scripts/m4-harness.sh launch 1400x900        # tmux attach で起動
Spikes/gate1/scripts/m4-harness.sh launch-bare 1400x900   # tmux 無しで bash 直起動
Spikes/gate1/scripts/m4-harness.sh ping 5                 # main thread の応答性 (往復ms)
Spikes/gate1/scripts/m4-harness.sh mem <label> [csv]      # RSS / phys_footprint を 1 サンプル
Spikes/gate1/scripts/m4-harness.sh sampler 15 <csv> <lbl> # 定期サンプリング (アプリのみ)
Spikes/gate1/scripts/m4-harness.sh soak-sampler 15 <csv>  # 定期サンプリング (アプリ + tmux サーバ)
Spikes/gate1/scripts/m4-harness.sh footprint <label>      # footprint(1) の全文を evidence へ
Spikes/gate1/scripts/m4-harness.sh teardown
```

| 追加物 | 目的 |
|---|---|
| `scripts/m4-harness.sh` | 上記の計測コマンド。証跡接頭辞は `m4` |
| `scripts/m4-checks/throughput.sh` | 大量出力スループット計測(pane 内で実行) |
| `scripts/m4-checks/fastui.sh` | 高速更新 TUI(`\r` 進捗バー + `top`) |
| `scripts/m4-checks/soak.sh` | 中期ソーク(5秒周期出力 + 60秒ごとの burst) |
| `TERMINAL_SPIKE_CONFIG_FILE` | **スパイク側の唯一のコード追加。** `ghostty_config_load_file` を呼ぶ環境変数フック。`scrollback-limit` を検証ごとに差し替えるために足した。ユーザーの `~/.config/ghostty/config` は読まない |

### 11.2 「UI の応答性」をどう測ったか

物理入力を合成できない環境なので(§7.2)、**制御チャネルの往復時間**を main thread の
応答性の代理指標にした。`m4-harness.sh ping` は

1. 制御ファイルへ `log PING-<id>` を追記する
2. アプリのログに `PING-<id>` が現れるまで 5ms 間隔でポーリングする
3. その所要時間を ms で出す

を行う。制御チャネルは main run loop 上の 100ms Timer で駆動されるため、
**アイドル時の期待値は 0〜100ms**(実測の中央値は約 93ms)。描画やパースで main thread が
詰まれば、この値がそのまま伸びる。伸びなければ「詰まっていない」と言える。

これに加えて、出力を流しっぱなしにした状態で

- ウィンドウリサイズ(`ctl resize` → `ghostty_surface_size()` の cols/rows が変わるか)
- `tmux split-window` / `select-pane`(CLI 操作に表示が追随するか)
- スクリーンショット撮影

を実際に行い、**機能が効くこと**も確認した。

### 11.3 スリープ対策(M4 で踏んだ罠)

**`caffeinate -u` はディスプレイスリープしか止めない。** M4 の途中で Mac 本体がシステムスリープし、
計測セッションが中断した。以後は `caffeinate -dimsu -t 7200` を 1 本立てて
システムスリープごと抑止し(**電源設定そのものは変更していない**)、作業終了時に確実に落とした。
`pmset -g assertions` で、終了後にアサーションが残っていないことを確認済み。

- §9.3 のとおり、ディスプレイスリープ中は `ghostty_surface_new` が失敗し `screencapture` も空振りする。
  M4 の 30〜45 分ソークは「放っておくと必ず寝る」長さなので、抑止は必須だった。
- ソークのサンプリングは**1 サンプルごとにファイルへ追記**する方式にしてある。
  再度中断されても途中までのデータが残り、集計を再開できる。

### 11.4 後片付け(M2 / M3 と同じ手順)

検証後、スパイクアプリ・`gate1-spike` / `gate1-hist` の tmux サーバ・`caffeinate`・一時ファイル
(`/tmp/gate1-m2`、`/tmp/gate1-m4`)をすべて破棄した。
**ユーザーの既定 tmux サーバのセッション一覧・`mouse` / `window-size` / `prefix` / `history-limit` が
検証前と完全一致することを確認済み**(`evidence/m4-default-tmux-before.txt` と
`m4-default-tmux-after.txt` は `diff` で差分ゼロ)。`open -na Ghostty` は M2 の教訓どおり一度も使っていない。

### 11.5 スループットの測り方

`scripts/m4-checks/throughput.sh` は各ワークロードについて

1. まず `| wc -lc` へ流してバイト数・行数を確定(端末へは出さない)= `gen_sec`
2. 同じコマンドを端末へ流し、その所要時間を測る = `term_sec`

を行う。`term_sec` は「生成コスト + 端末が受け取り切るまで」であり、**端末単体の描画時間ではない**。
`gen_sec` を併記してあるので、生成側の寄与は読み取れる。同じスクリプトを
**tmux 経由(`launch`)と tmux 無し(`launch-bare`)の両方**で回して比較した。

---

## 12. M4 の結果

環境: macOS 26.5.2 (25F84) arm64 / ghostty v1.3.1 / tmux 3.4 / ウィンドウ 1400x900 pt
(= 174桁 × 50行、Retina backingScaleFactor 2.0)。ユーザーの `~/.tmux.conf` をそのまま使用
(`history-limit 10000`、`window-size latest`、prefix `C-q`、`mouse on`)。pane 内の shell は fish。

### 12.1 結果一覧

| # | 検証項目 | 結果 | 証跡 |
|---|---|---|---|
| 1 | 大量出力: `seq 1 1000000` / 50MB ファイルの `cat` / `yes` 300万行 / base64 50MB / `find /usr` | ✅ 全て完走。詰まり・取りこぼし無し | §12.2 |
| 2 | 出力中の UI 応答性(制御チャネル往復) | ✅ **悪化しない**(アイドル中央値 93ms → 出力中 12〜119ms) | §12.3 |
| 3 | 出力中のウィンドウリサイズ | ✅ 174x50 → 112x33 に追随 | §12.3 |
| 4 | 出力中の `tmux split-window` / `select-pane` | ✅ 即時追随。新 pane も正常描画 | `m4-01-during-output-split.png` |
| 5 | 出力停止後の表示収束 | ✅ `capture-pane` の内容と画面が完全一致 | `m4-02-convergence-after-output.png` |
| 6 | 高速更新 TUI(`\r` 進捗バー 268更新/秒) | ✅ 残像・欠け無し | `m4-03-fastui-progress.png` / `m4-04-fastui-top.png` |
| 7 | `top`(alternate screen、1秒更新) | ✅ 正常 | `m4-04` |
| 8 | tmux 無し(`launch-bare`)での同一ワークロード | ✅ 完走。応答性も維持 | §12.2 / `m4-05-bare-convergence.png` |
| 9 | メモリ: 起動直後 → 大量出力直後 → 出力後アイドル | ✅ 出力中に一時増加し、停止後に戻る | §12.4 |
| 10 | `scrollback-limit` とメモリの関係 | ✅ **設定値がそのままメモリ量になる**(10MB → +17MB / 100MB → +103MB) | §12.5 |
| 11 | tmux サーバ側のメモリ / `history-limit` の効き | ⚠️ **無視できない**(履歴を溜めると 140MB。`history-limit × 桁数` に比例) | §12.5 |
| 12 | 中期ソーク(35.6分、416 回の周期出力 + 34 回の burst = 約68万行) | ✅ **プラトー。リーク疑いなし**(前半平均 104,607 KB / 後半平均 104,626 KB) | §12.6 / `m4-soak-samples.csv` / `m4-07-soak-end.png` |
| 13 | 数時間〜数日規模の長時間稼働 | **未検証**(スパイクの範囲外。本実装後に計測する) | — |
| 14 | 複数 surface 同時(5〜10)のメモリ / CPU | **未検証**。スパイクは 1 surface 固定で、複数 surface は実装していない | §12.7 |
| 15 | `ghostty_surface_free` の反復生成/破棄によるリーク | **未検証**(同上。surface の作り直し経路が無い) | §12.7 |
| 16 | スリープ / 復帰、外部ディスプレイ抜き差し、background / foreground 復帰 | **未検証(要手動確認)**。§9.3 のディスプレイスリープ問題は M4 でも再現 | §12.7 |

### 12.2 大量出力スループット(実測値)

`term_sec` = 端末へ流し切るまでの秒数。`gen_sec` = 同じコマンドを `wc` へ流したときの秒数(生成コストの目安)。
生データ: `evidence/m4-throughput.csv`。

| ワークロード | バイト数 | 行数 | tmux 経由 `term_sec` / MB/s | tmux 無し `term_sec` / MB/s | `gen_sec`(参考) |
|---|---:|---:|---|---|---|
| `seq 1 1000000` | 6,888,900 | 1,000,001 | 0.774 s / **8.49** | 1.004 s / 6.54 | 0.17 s |
| `cat` 50MB テキスト(65桁) | 50,160,000 | 760,000 | 3.157 s / **15.15** | 0.746 s / **64.12** | 0.07 s |
| `yes \| head -n 3000000`(2バイト行) | 6,000,000 | 3,000,000 | 2.048 s / **2.79** | 3.608 s / 1.59 | 0.15 s |
| `base64 -b 76` 50MB | 50,657,895 | 657,895 | 3.091 s / **15.63** | 3.056 s / 15.81 | 0.11 s |
| base64 改行なし(10MB を 1 行) | 10,000,001 | 1 | 0.552 s / **17.28** | 0.639 s / 14.92 | 0.03 s |
| `find /usr -print` | 1,003,430 | 23,245 | 0.164 s / 5.84 | 0.275 s / 3.48 | 0.11〜0.24 s |

読み取れること:

- **どのワークロードも数秒で完走し、ハングも取りこぼしも無い。** 50MB のログを `cat` しても
  3 秒(tmux 経由)/ 0.75 秒(tmux 無し)で収まる。ビルドログを流す用途で問題になる水準ではない。
- **tmux を挟むと長い行では遅くなり、短い行の連打では速くなる。**
  - `cat` 50MB は tmux 経由が 4 倍遅い(15 vs 64 MB/s)。tmux が全バイトをパースして自分の
    履歴へ積み、さらにクライアント向けに再エンコードするコストが乗るため。
  - 逆に `yes`(300万行)は tmux 経由のほうが速い(2.79 vs 1.59 MB/s)。tmux が画面更新を
    まとめてからクライアントへ送るので、**libghostty が処理する行数自体が減る**。
  - つまり tmux は「スループットの上限を下げる代わりに、クライアント側の負荷を平滑化する」。
    本製品は常に tmux を挟む(§4.1 確定)ので、**後者の特性が効く。**
- 改行なし 10MB の単一行(折り返し 57,000 行相当)でも破綻しない。

### 12.3 出力中の UI 応答性

制御チャネル往復(ms)。アイドル時の期待値は 0〜100ms(100ms ポーリング)。

| 局面 | 往復時間 |
|---|---|
| アイドル(基準) | 44.4 / 95.3 / 95.4 / 99.0 / 93.3 / 94.5 / 101.0 / 91.8 |
| `seq` 出力中 | 119.1 / 6.4 |
| `cat` 50MB 出力中 | 25.3 / 50.4 / 44.1 / 49.5 / 50.4 / 43.4 / 42.0 / 56.7 |
| `yes`+base64+`find` 連続出力中 | 12.7〜76.2(16 サンプル) |
| `yes` 連続出力中(無限) | 88.2 / 94.4 / 93.6 |
| tmux 無し・大量出力中 | 37.8〜67.8(20 サンプル) |

**基準値より悪化していない。** むしろ出力中のほうが小さい値が出るのは、
Timer の位相と偶然揃うため(出力があると main thread が頻繁に起きる)。
撤退基準 §7-6「大量出力で入力応答が失われる」に**該当する事象は観測されなかった**。

出力を流しっぱなしにした状態で行った機能確認:

- `ctl resize 900 600` → `ghostty_surface_size()` が `cols=112 rows=33 px=1800x1136` に更新される。
  tmux クライアントも 112x32 へ追随(SIGWINCH が通っている)。
- `tmux split-window -h` → 2 pane に分割され、**出力中の pane も新しい pane も正しく描かれる**
  (`m4-01-during-output-split.png`。左 pane に日本語・絵文字混じりの高速出力、右 pane に fish のプロンプト)。
- `tmux select-pane` → active pane が切り替わる。
- 出力停止 → `clear` + sentinel 出力後、**画面と `capture-pane -p` の内容が完全一致**
  (`m4-02-convergence-after-output.png`)。取り残しや古い描画は無い。

### 12.4 メモリ(RSS / phys_footprint)

`ps -o rss` と `footprint -p` の実測。生データ: `evidence/m4-mem-tmux.csv` / `m4-mem-bare.csv`。

**tmux 経由(合計 約125MB を出力)**

| 局面 | RSS | phys_footprint |
|---|---:|---:|
| (a) 起動直後 | 100,848 KB (98.5 MB) | 100,352 KB (98.0 MB) |
| 出力中のピーク | 105,104 KB | **146,432 KB (143 MB)** |
| (b) 大量出力直後 | 109,216 KB (106.7 MB) | 106,496 KB (104.0 MB) |
| 高速更新 TUI 後 | 111,136 KB | 106,496 KB |
| (c) 出力停止後 5〜6 分アイドル | 110,768 KB (108.2 MB) | 104,448 KB (102.0 MB) |

**tmux 無し(同一ワークロード、既定 `scrollback-limit` = 10MB)**

| 局面 | RSS | phys_footprint |
|---|---:|---:|
| 起動直後 | 100,368 KB | 103,424 KB |
| 大量出力直後 | 117,696 KB (114.9 MB) | 126,976 KB (124 MB)、peak 149 MB |

- **出力中に一時的に 40MB ほど増え、停止後に解放される。** (b)→(c) で footprint がむしろ
  減っている(106.5MB → 104.4MB)ので、出力そのものによるリークは見えない。
- tmux 経由のほうが増加が小さい(+6MB vs +23MB)。**履歴を持つのが tmux 側だから**である。
  tmux 無しでは libghostty が自前の scrollback に全部積む(§12.5)。
- 起動直後の約 100MB は Metal / フォント / libghostty の固定コスト。M1 の参考値と一致する。

### 12.5 scrollback とメモリ(§24「スクロールバック上限の挙動」)

`TERMINAL_SPIKE_CONFIG_FILE` で `scrollback-limit` だけを変え、tmux 無しで
50MB のファイルを 3 回(計 150MB)流した。生データ: `evidence/m4-mem-scrollback.csv`。

| `scrollback-limit` | 起動直後 footprint | 150MB 出力後 footprint | 増分 |
|---|---:|---:|---:|
| 10,000,000(**既定**) | 99,328 KB | 116,736 KB | **+17.0 MB** |
| 100,000,000 | 98,304 KB | 201,728 KB | **+103.1 MB** |

- **`scrollback-limit`(バイト)がほぼそのまま常駐メモリ増になる。** 上限に達すると頭から
  捨てられるので、いくら出力してもそれ以上は増えない(= 上限として正しく機能している)。
- 既定の 10MB は「1 surface あたり最大 +17MB 程度」を意味する。
  **§4.1 の「1タスク=1タブ」で 5〜10 タブを同時に開く設計では、この値が直接効く。**

**tmux サーバ側のメモリも無視できない。**

| 対象 | RSS |
|---|---:|
| `gate1-spike` サーバ(起動直後、1 pane) | 4,368 KB |
| `gate1-spike` サーバ(§12.2 の全ワークロードを流した後、最大 2 pane) | **143,904 KB (140 MB)** |
| ユーザーの既定サーバ(アイドルのセッション 3 つ) | 1,456 KB |

`history-limit 10000`(ユーザー設定)× 174 桁 × pane 数ぶんの履歴が tmux サーバに載る。
**アプリのメモリだけを見ていると全体像を見誤る**ことが分かった。

これを切り分けるため、**アプリを一切介さず**別ソケット(`-L gate1-hist`、`-f /dev/null`)で
174x50 の pane を作り、50MB のファイルを `cat` させて tmux サーバ単体のメモリを測った。

| `history-limit` | 開始時 RSS | 50MB 出力後 RSS | `#{history_bytes}` | 1 行あたり |
|---|---:|---:|---:|---:|
| 10,000 | 3,680 KB | **25,376 KB** | 19,714,292 | 約 1,980 B |
| 100,000 | 3,760 KB | **215,632 KB** | 197,014,292 | 約 1,970 B |

- **tmux の履歴メモリは `history-limit × 桁数` にきれいに比例する**(174 桁で 1 行あたり約 2KB)。
- **これは pane 単位である。** §4.1 の「1タスク = 1 worktree = 1 tmux session」で
  10 タスク × 各数 pane を開けば、tmux サーバだけで数百 MB になりうる。
  `history-limit` の既定値をユーザーの `~/.tmux.conf` 任せにするのか、
  セッション生成時に製品として明示するのかは**設計判断が要る**。

### 12.6 中期稼働ソーク(35分)

`scripts/m4-checks/soak.sh 35` を tmux pane で回した。5 秒ごとに
「時刻 + カラー + 日本語 + 絵文字 + 下線」の 1 行、60 秒ごとに 2 万行の burst。
サンプリングは `m4-harness.sh soak-sampler 15`(アプリと tmux サーバの両方を 15 秒間隔)。
**セッションが切れても途中まで残るよう、1 サンプルごとに `evidence/m4-soak-samples.csv` へ追記する**方式にした。

- 期間: 20:32:26 〜 21:07:30(**35.6 分**、416 イテレーション、burst 34 回 = 約 68 万行)
- サンプル数: アプリ 142 / tmux サーバ 142

| 指標 | 開始 | 終了 | 最小 | 最大 |
|---|---:|---:|---:|---:|
| アプリ RSS | 100,064 KB | 104,608 KB | 100,064 KB | 104,816 KB |
| アプリ phys_footprint | 99,328 KB | 105,472 KB | 99,328 KB | 106,496 KB |
| tmux サーバ RSS | 4,448 KB | 10,128 KB | 4,448 KB | 10,128 KB |

**判定: プラトー(リークの疑いなし)。**

- RSS の増加 +4,544 KB は**最初の 1 分でほぼ全部**起きている(初回描画とフォントアトラスの
  ウォームアップ)。以後は横ばい。
- **前半 17.8 分の平均 104,607 KB に対し、後半 17.8 分の平均は 104,626 KB。差は +19 KB**
  (0.02%)。単調増加なら後半平均が明確に上回るはずであり、その傾向は出ていない。
- `phys_footprint_peak` は 136 MB(burst 中の一時的なピーク)だが、定常値は 103 MB に戻る。
- tmux サーバは `history-limit 10000` に達するまで増え、そこで頭打ち(10 MB)になった。
  **上限が上限として機能している。**
- ソーク終了直後の制御チャネル往復は 60.9 / 87.0 / 104.8 / 72.4 ms で、**起動直後の基準値と同じ**。
  35 分連続稼働で応答性が劣化していない。
- アプリのログには 35 分を通して**エラー・警告が 1 行も出ていない**(`/tmp/gate1-m2/app.log`)。
- 最終画面(`m4-07-soak-end.png`)は burst の末尾・色付き行・`SOAK COMPLETE` まで正しく描かれている。

**この結果が言えること / 言えないこと:**

- 言える: **35 分・68 万行規模では、libghostty 側にも tmux 側にもリーク傾向は見えない。**
- 言えない: 数時間〜数日規模。撤退基準 §7-6 の「長時間稼働で RSS が単調増加し実用時間内に破綻する」を
  完全に否定するには不足であり、**未検証(本実装後に実作業で計測)として残す**(§12.7-1)。

### 12.7 未検証(手動確認が必要 / 本実装後に回すもの)

M2 §8.9・M3 §10.8 の項目に加えて、M4 では以下が残った。**楽観的に埋めず、未検証として記録する。**

1. **数時間〜数日規模の長時間稼働。** 今回は 35 分。PLAN.md M4 は「8時間以上」を挙げていたが、
   スパイクの実行環境(セッションが切れる、スリープする)では信頼できる計測ができない。
   **本実装後、実際の開発作業で 1 日走らせて RSS を記録するのが正しい測り方**であり、
   ここでの 35 分は「短期のリーク傾向が無い」ことしか言えない。
2. **複数 surface(5〜10)同時のメモリ / CPU。** スパイクは 1 surface 固定で、
   複数 surface / 複数ウィンドウを実装していない。§12.5 の測定から
   「1 surface あたり固定 ~100MB(プロセス共有部分を含む) + scrollback 上限まで」という
   見積り式は立つが、**surface を N 枚にしたときの実測ではない**。
3. **`ghostty_surface_free` の反復生成/破棄によるリーク。** 同上。
   なお §8.2 の「detach すると surface のプロセスが死ぬ」問題により、
   本体では surface の作り直しが**必須**になる見込みなので、ここは本実装の初期に潰すべき。
4. **スリープ / 復帰、外部ディスプレイ抜き差し、background / foreground 復帰。**
   §9.3 のディスプレイスリープ問題(surface 生成失敗)は M4 でも再現しており、
   計測中は `caffeinate` でスリープを抑止して回避した。**復帰時の挙動は未検証。**
5. **物理入力・描画品質・体感遅延**(M2 §8.9 から継続)。

### 12.8 M4 で見つかった設計影響事項

1. **`scrollback-limit` はメモリ予算の主要パラメータである**(§12.5)。
   `TerminalRenderer` は **設定ロード経路**(v1.3.1 では `ghostty_config_load_file`)を
   持つ必要があり、scrollback をタブ単位で変えられるかは本体の設計事項になる。
2. **メモリはアプリと tmux サーバの 2 か所に載る**(§12.5)。`history-limit` の既定値を
   製品としてどう扱うか(ユーザーの `~/.tmux.conf` を尊重するのか、セッション生成時に
   明示指定するのか)を決める必要がある。
3. **tmux は負荷の平滑化装置として働く**(§12.2)。tmux を挟むぶん最大スループットは
   下がるが、クライアント側の描画負荷は減る。tmux 前提(§4.1 確定)はここでも有利に働く。
4. **`footprint` のピーク値は定常値より 40MB 高い**(§12.4)。メモリ上限を設計するときは
   定常 RSS ではなくピークで見積もること。
