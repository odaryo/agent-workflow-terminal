# Gate 1 スパイク — M0 / M1 / M2 実施記録

- 実施日: 2026-08-31
- ブランチ: `spike/gate1-terminal-poc`
- 対象: `PLAN.md` の **M0(準備)** / **M1(SwiftUI ウィンドウで zsh が動く)** / **M2(tmux attach と操作検証)**
- 状態: **M0 完了 / M1 完了 / M2 完了**。M3 以降は未着手。

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
| `TERMINAL_SPIKE_COMMAND` | surface の command。既定 `/bin/zsh`。M2 では `tmux -L gate1-spike new-session -A -s gate1-spike` |
| `TERMINAL_SPIKE_USER_CONFIG=1` | `~/.config/ghostty/config` を読み込む(既定は読まない) |
| `TERMINAL_SPIKE_RESIZE_TEST=1` | 起動後に 3 サイズへリサイズして `ghostty_surface_size()` をログ出力する計測フック |
| `TERMINAL_SPIKE_EXIT_AFTER=<秒>` | 指定秒後に自動終了(検証用) |
| `TERMINAL_SPIKE_CONTROL=<path>` | **M2 の制御チャネル**。このファイルへ追記した行をコマンドとして実行する(§9.2) |

M2 の検証は `scripts/m2-harness.sh` から駆動する。

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
│   ├── build-app.sh            TerminalSpike.app の組み立て (M1)
│   └── m2-harness.sh           M2 検証ハーネス (launch / ctl / shot / teardown)
├── TerminalSpike/
│   ├── Package.swift           SwiftPM executable + binaryTarget
│   └── Sources/TerminalSpike/
│       ├── TerminalSpikeApp.swift    SwiftUI App / AppDelegate / 計測フック
│       ├── GhosttyTerminalView.swift libghostty 呼び出しの唯一の場所
│       └── SpikeControl.swift        M2 の制御チャネル (GhosttyKit を import しない)
├── evidence/
│   ├── m1-zsh.png              M1 の証跡(ウィンドウのみ)
│   └── m2-01..23-*.png         M2 の証跡
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

## 9. 次にやること(M3)

1. tmux 内で **Claude Code** と **Codex CLI** を実際に動かす(§12 の Agent 非依存方針上、片方だけでは不可)。
2. 日本語 IME: `NSTextInputClient` 準拠 → `ghostty_surface_preedit` / `ghostty_surface_ime_point` の接続。
   **M1 / M2 とも IME は未実装のまま。** ここが撤退基準 §7-3 に直結する。
3. 全角幅・絵文字・grapheme cluster・tmux pane 境界での欠け。
4. 質問 / 権限プロンプト時の表示崩れ(設計書 §11 の前提)。
5. `Ghostty.app` との差分表を作り、差分があれば「埋め込み方の問題」か「libghostty の問題」かを切り分ける。
