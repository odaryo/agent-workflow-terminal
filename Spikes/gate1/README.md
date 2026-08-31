# Gate 1 スパイク — M0 / M1 実施記録

- 実施日: 2026-08-31
- ブランチ: `spike/gate1-terminal-poc`
- 対象: `PLAN.md` の **M0(準備)** と **M1(SwiftUI ウィンドウで zsh が動く)**
- 状態: **M0 完了 / M1 完了**。M2 以降は未着手。

> この文書は「やってみて何が分かったか」の記録である。
> `docs/architecture.md` の状態区分(確定／現在の推奨／未確定／対象外)は一切変更していない。
> libghostty は依然 §21.1 の「現在の推奨」であり、本スパイクは昇格も降格もしない。

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
| `TERMINAL_SPIKE_COMMAND` | surface の command。既定 `/bin/zsh`。M2 では `tmux new-session -A -s spike` を入れる |
| `TERMINAL_SPIKE_USER_CONFIG=1` | `~/.config/ghostty/config` を読み込む(既定は読まない) |
| `TERMINAL_SPIKE_RESIZE_TEST=1` | 起動後に 3 サイズへリサイズして `ghostty_surface_size()` をログ出力する計測フック |
| `TERMINAL_SPIKE_EXIT_AFTER=<秒>` | 指定秒後に自動終了(検証用) |

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
| tmux split/zoom/attach/detach | 未着手 | M2 |
| mouse protocol | 未着手(コードのみ実装) | M2 |
| copy/paste・selection・URL hit testing | 未着手 | M2 |
| IME・日本語・絵文字・grapheme width | 未着手 | M3 |
| 大量output・長時間稼働・memory | 未着手 | M4。参考値として起動直後 RSS ≒ 100MB |

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
| IME(M3) | `NSTextInputClient` 準拠、`interpretKeyEvents`、`markedText` | preedit と候補ウィンドウ位置 |
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
│   └── build-app.sh            TerminalSpike.app の組み立て (M1)
├── TerminalSpike/
│   ├── Package.swift           SwiftPM executable + binaryTarget
│   └── Sources/TerminalSpike/
│       ├── TerminalSpikeApp.swift    SwiftUI App / AppDelegate / 計測フック
│       └── GhosttyTerminalView.swift libghostty 呼び出しの唯一の場所
├── evidence/
│   └── m1-zsh.png              M1 の証跡(ウィンドウのみ)
├── vendor/ghostty/             ghostty v1.3.1 の shallow clone (git 管理外)
├── build/                      TerminalSpike.app (git 管理外)
└── .build-shim/                libtool シム (git 管理外)
```

`vendor/` `build/` `.build-shim/` `TerminalSpike/.build/` は `.gitignore` 済み。
`evidence/` も `.gitignore` 済み(スクリーンショット等は容量が大きいため Git 管理せず、ローカルにのみ保持する)。

---

## 7. 次にやること(M2)

1. `TERMINAL_SPIKE_COMMAND='tmux new-session -A -s spike'` で attach する。
2. prefix キーが libghostty のキーバインドに食われないか。split / zoom / detach / 再 attach。
3. `set -g mouse on` での pane 選択・リサイズ・スクロール。
4. copy-mode とアプリ側 selection の衝突。
5. `Ghostty.app` と PoC アプリの**同一 tmux session 同時 attach**。
6. `tmux send-keys` によるテキスト注入(PLAN.md §6.2)。
7. **v1.3.1 に `foreground_pid` / `tty_name` が無い**前提で、pane 特定手段を洗い直す(§3.3-3)。
