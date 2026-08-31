# Gate 1 PoC スパイク計画 — macOS Terminal品質

- 作成日: 2026-08-31
- ブランチ: `spike/gate1-terminal-poc`
- 対象: `docs/architecture.md` §24 「Gate 1: macOS Terminal品質 — 最優先」
- ステータス: **調査と計画のみ**。実装は未着手。

---

## 0. この文書の位置付け

本文書は Gate 1 PoC に着手するための**調査結果と作業計画**であり、設計判断ではない。

- `docs/architecture.md` の状態区分(確定／現在の推奨／未確定／対象外)を**変更しない**。libghostty は §21.1 で「現在の推奨」であり、本文書はそれを昇格も降格もしない。
- PoCコードは**スパイク品質**とし、`Spikes/` 配下に隔離する。本体コードへは持ち込まない。得るのは知見であり、コードではない。
- 調査で判明した代替案は「選択肢として記録する」に留める。**採用判断はユーザーが行う。**

---

## 1. 目的

`SwiftUI + libghostty + PTY + tmux attach` の構成で、実際の Claude Code / Codex / shell を動かし、
**本体の実装に進んでよい品質か**を判断できる材料を集める。

Gate 1 が最優先である理由(§24): これが不成立なら、UI全体の実装へ進む前に Terminal renderer 候補を再評価する必要がある。
つまり Gate 1 は他のすべての UI 作業をブロックする。

---

## 2. §24 Gate 1 チェックリスト(設計書からの転記)

> `SwiftUI + libghostty + PTY + tmux attach`で、実際のClaude Code／Codex／shellを動かす。
>
> 確認事項:
>
> - VT互換性
> - Metal描画とresize
> - IME、日本語入力、絵文字、grapheme width
> - copy／paste、selection、URL／path hit testing
> - mouse protocol
> - tmux split／zoom／attach／detach
> - 大量output、長時間稼働、memory
> - AppKit bridgeが必要な範囲

関連する確定事項・推奨事項:

- §21.5 libghostty隔離: アプリ全体を libghostty API へ直接依存させず、`TerminalRenderer` protocol の背後へ隔離する。**PoCが成立しない場合に renderer だけ差し替えられる境界を維持する。**
- §4 tmuxモデル(確定): 1タスク = 1 worktree = 1タブ = 1 専用 tmux session。tmux を再実装しない。pane 分割・キーバインド・session管理は tmux 側に残す。
- §23 ライセンス方針: permissive(MIT/BSD/ISC/Apache-2.0)のみ。GPL/LGPL/AGPL および不明ライセンスは原則不採用。

---

## 3. 環境調査結果(2026-08-31 時点、実機で確認)

| 項目 | 結果 | 備考 |
|---|---|---|
| macOS | 26.5.2 (build 25F84) | ghostty main は macOS 26 SDK を要求。条件を満たす |
| CPU | arm64 (Apple Silicon) | x86_64 スライスは実機検証不可。universal ビルドはクロスコンパイルのみ |
| Xcode | 26.5 (17F42) | ghostty main branch は **Xcode 26 + macOS 26 SDK 必須**。条件を満たす |
| Swift | 6.3.2 (swiftlang-6.3.2.1.108) / target arm64-apple-macosx26.0 | §21.1 の Swift 6 前提を満たす |
| zig | **未インストール** (`which zig` → not found) | 要インストール。§5.2 参照 |
| Homebrew の zig | `zig` = 0.16.0 (alias `zig@0.16`)、`zig@0.15` = 0.15.2 (keg-only) | 両方入手可能 |
| Ghostty.app | 1.3.1 (Homebrew Cask、`/Applications/Ghostty.app`) | 参照実装として挙動比較に使える。ただし配布バイナリに `GhosttyKit.xcframework` やヘッダは含まれない(アプリへ静的リンク済み) |
| tmux | 別途確認が必要(未計測) | M2 開始時に `tmux -V` を記録すること |

**メモ:** Ghostty.app がインストール済みなので、「本家 Ghostty ではどう見えるか」を同一マシン上で常に比較できる。
VT互換性・IME・grapheme width の検証では、PoC アプリと Ghostty.app の**差分**が libghostty の埋め込み方の問題か、libghostty 自体の挙動かを切り分ける基準になる。

---

## 4. libghostty 調査結果(2026-08-31 時点)

### 4.1 最重要: 「libghostty」は今2つある

| | libghostty-vt | 完全版 libghostty (GhosttyKit) |
|---|---|---|
| 中身 | VTパーサ + terminal state のみ。描画・入力・PTYなし | Ghostty GUI コア全体。Metal描画・入力・PTY・設定を含む |
| C API | 公開済み・整備が進行中。`include/ghostty/vt.h`、ABI型マニフェストと検証step(`test-lib-vt-schema`)あり | `include/ghostty.h`。**macOSアプリ専用の内部境界という位置付け** |
| サンプル | `example/` に30本以上(`c-vt-*`, `swift-vt-xcframework`, `cpp-vt-stream`, `wasm-vt` 等) | **リポジトリに埋め込みサンプルなし**(唯一の利用者が `macos/` の Ghostty.app 本体) |
| 対応 | macOS / iOS / Linux / Windows / WebAssembly | **main では macOS のみ**(§4.6 参照) |
| Gate 1 での位置 | 描画を自作する場合の素材 | **Gate 1 が検証する対象はこちら** |

公式ドキュメントの明示:

> "The libghostty API is currently used primarily by the macOS app and **is not yet stabilized for general-purpose embedding**. The API may change significantly between releases."
>
> "The current libghostty API is **not stable**."

つまり **Gate 1 が依存する API は、公式には「安定APIとして提供されていない」**。
機能自体は Ghostty GUI で長期間実証済みで安定しているが、シグネチャは release 間で変わりうる。
`build.zig` 上でも libghostty のバージョンはアプリ本体と分離され `lib_version = "0.1.0-dev"` である。

将来的には入力・GPU描画・Swift フレームワークを含む libghostty 群が提供される計画だが、**現時点では未提供**。

### 4.2 ビルド手順(調査で判明した具体手順)

前提: Xcode + macOS SDK + Metal Toolchain がインストール済みで `xcode-select` が正しいこと。

```shell
sudo xcode-select --switch /Applications/Xcode.app

git clone https://github.com/ghostty-org/ghostty
cd ghostty
git checkout v1.3.1        # ピン留め方針は §4.7 を参照

zig build \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Doptimize=ReleaseFast
```

- 成果物: **`macos/GhosttyKit.xcframework`**(ghostty リポジトリ**直下**の `macos/`。`zig-out/` **ではない**)
  - `Headers/ghostty.h`(公開Cヘッダ 1枚)
  - `Modules/module.modulemap`(module 名は `GhosttyKit`。Swift から `import GhosttyKit` になる)
  - 静的ライブラリ本体 + dSYM
  - **訂正(M0 実測、2026-08-31):** 当初この節は `zig-out/macos/GhosttyKit.xcframework` と書いていたが誤り。
    v1.3.1 の `src/build/GhosttyXCFramework.zig` は `out_path = "macos/GhosttyKit.xcframework"` であり、
    xcframework はリポジトリ直下の `macos/` に出る。`zig-out/` に入るのは
    `share/`(terminfo・shell-integration・themes)と `include/`、および `libghostty-vt` の dylib のみ。
- `-Dxcframework-target` は `native` | `universal` の2値。**PoC は `native`(arm64のみ)で十分**。`universal` は macOS の universal ビルドを作る。
- `-Demit-xcframework=true` の場合、**resources も必ず install される**(ビルドスクリプトのコメント: "The xcframework build always installs resources because our macOS xcode project contains references to them")。→ §4.5
- デバッグしたい場合は `-Doptimize` を外すと debug ビルドになる。

**必要な zig のバージョン**(`build.zig.zon` の `minimum_zig_version` で強制、`comptime` チェックで即エラーになる):

| ghostty ref | version | minimum_zig_version |
|---|---|---|
| `main` | 1.3.2-dev | **0.16.0** |
| `v1.3.1` (最新タグ) | 1.3.1 | **0.15.2** |

Homebrew では `brew install zig`(0.16.0) と `brew install zig@0.15`(0.15.2、keg-only)の両方が入手できる。
ピン留めするタグに合わせて選ぶこと。両方入れて `ZIG_BIN` 相当で切り替える運用も可能。

### 4.3 プリビルド版という選択肢(ビルド省略ルート)

自前ビルドせずに済ませる経路も存在する。M1 の立ち上げを速くしたい場合の候補。

| 名前 | URL | 内容 |
|---|---|---|
| libghostty-spm | https://github.com/Lakr233/libghostty-spm | プリビルド `GhosttyKit.xcframework` を Swift Package として配布。macOS 13+ / iOS 15+ / Catalyst / visionOS。現行版は Ghostty **v1.3.1** 同梱、zig 0.15.2 でビルド。MIT。`GhosttyKit`(C API 再輸出)、`GhosttyTerminal`(SwiftUI ラッパ `TerminalSurfaceView` 等)、`GhosttyTheme` の3プロダクト |
| Termini | https://github.com/arach/Termini | libghostty ベースの SwiftUI terminal surface。macOSローカルPTY(`forkpty`)+ SwiftNIO SSH(iOS/macOS)。SwiftPM が GitHub Releases からプリビルド xcframework を自動取得。MIT |

**注意(§23 ライセンス方針との関係):** これらはサードパーティ配布物である。ライセンス自体は MIT で方針に適合するが、
「バイナリ配布物を第三者リポジトリから取得する」ことのサプライチェーン上の是非は別問題。
**PoC段階では検証速度優先で使ってよいが、本採用の判断材料にはしない**。本採用時は upstream から自前ビルドする前提で計画する。

### 4.4 C API の公開範囲(`include/ghostty.h` を実読して確認、main、全1278行)

**ライフサイクル**
- `ghostty_init(argc, argv)` — プロセス起動時に1回
- `ghostty_config_new/load_default_files/load_file/finalize/free`、`ghostty_config_diagnostics_count/get_diagnostic`(設定エラー検出)
- `ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t)` / `ghostty_app_free`
- `ghostty_app_tick(app)` — IO・タイマー処理。ホスト側の run loop から駆動する
- `ghostty_app_set_focus` / `ghostty_app_key` / `ghostty_app_keyboard_changed` / `ghostty_app_set_color_scheme` / `ghostty_app_update_config`

**surface(= 1ターミナルビュー)**
```c
typedef struct { void* nsview; } ghostty_platform_macos_s;
typedef struct { void* uiview;  } ghostty_platform_ios_s;

typedef struct {
  ghostty_platform_e platform_tag;   // GHOSTTY_PLATFORM_MACOS | _IOS
  ghostty_platform_u platform;       // .macos.nsview に NSView* を渡す
  void* userdata;
  double scale_factor;
  float  font_size;
  const char* working_directory;
  const char* command;
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;  // WINDOW | TAB | SPLIT
} ghostty_surface_config_s;

ghostty_surface_t ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*);
```

**描画・サイズ**
`ghostty_surface_draw`、`ghostty_surface_refresh`、`ghostty_surface_set_size(w,h)`、`ghostty_surface_size()`(columns/rows/px/cell size を返す)、`ghostty_surface_set_content_scale`、`ghostty_surface_set_focus`、`ghostty_surface_set_occlusion`、`ghostty_surface_set_display_id`

**入力**
`ghostty_surface_key`、`ghostty_surface_key_is_binding`、`ghostty_surface_text`、**`ghostty_surface_preedit`**(IME変換中テキスト)、**`ghostty_surface_ime_point`**(IME候補ウィンドウ位置)、`ghostty_surface_key_translation_mods`、`ghostty_surface_mouse_button/mouse_pos/mouse_scroll/mouse_pressure`、`ghostty_surface_mouse_captured`(mouse protocol でアプリ側がマウスを掴んでいるか)

**選択・クリップボード**
`ghostty_surface_has_selection`、`ghostty_surface_read_selection`、`ghostty_surface_read_text`、`ghostty_surface_free_text`、`ghostty_surface_complete_clipboard_request` / `deny_clipboard_request`、`ghostty_surface_quicklook_word` / `quicklook_font`

**プロセス観測(Agent Adapter にとって重要)**
- `ghostty_surface_process_exited(surface) -> bool`
- ~~`ghostty_surface_foreground_pid(surface) -> uint64_t`~~
- ~~`ghostty_surface_tty_name(surface) -> ghostty_string_s`~~

> **訂正(M0 実測、2026-08-31): `ghostty_surface_foreground_pid` と `ghostty_surface_tty_name` は
> v1.3.1 の `ghostty.h` に存在しない。** 本節は upstream `main` のヘッダを読んで書かれており、
> この 2 関数は v1.3.1 より後に追加されたもの。v1.3.1(§4.7 案A)へピン留めする限り、
> surface からプロセスを直接観測する手段は `ghostty_surface_process_exited` のみである。
> → **Gate 3(Agent Adapter)への申し送り:** pane / プロセス特定は
> `tmux list-panes -F '#{pane_pid}'` 等の tmux CLI に頼る必要がある。
> §6.3 の懸念は「tmux を挟むと何が返るか」以前に「そもそも API が無い」だった。

**コールバック**(`ghostty_runtime_config_s` に関数ポインタで登録)
- wakeup(イベントループ起床)
- **action**(ターミナルからホストへの要求。`GHOSTTY_ACTION_*` は約60種: `SET_TITLE`、`PWD`、`DESKTOP_NOTIFICATION`、`MOUSE_OVER_LINK`、`MOUSE_SHAPE`、`RENDER`、`RENDERER_HEALTH`、`CELL_SIZE`、`OPEN_URL`、`NEW_SPLIT`、`TOGGLE_SPLIT_ZOOM`、`GOTO_SPLIT`、`CLOSE_TAB` 等)
- read/write clipboard、close surface

**PTY の所有者は libghostty 側**。`command` / `working_directory` / `env_vars` を surface config で渡すと libghostty が子プロセスを起動して PTY を管理する。
→ **ホスト側が生バイト列を PTY へ書き込む API は `ghostty.h` に存在しない**(入力は key / text / preedit 経由のみ)。§6.2 に設計上の含意を記す。

**未確認:** `ghostty_runtime_config_s` の全フィールド、`ghostty_action_u` の各 payload の詳細、スクロールバック取得API の有無、`ghostty_inspector_*` の使い所。M1 でヘッダ全体を読み切って埋めること。

### 4.5 リソース(terminfo / shell integration)

- ghostty は `GHOSTTY_RESOURCES_DIR` 環境変数でバンドルリソースの位置を探す(`src/os/resourcesdir.zig`)。release ビルドではこれを最優先で見る。debug ビルドでは terminfo 検出を先に試す。
- リソース内容: `share/terminfo/ghostty.terminfo`(+ termcap、コンパイル済みDB)、`src/shell-integration/`(bash/zsh/fish/elvish)。
- `zig build -Demit-xcframework=true` はこれらを `zig-out/share/...` へ install する。
- **訂正(M0/M1 実測、2026-08-31): `GHOSTTY_RESOURCES_DIR` が指すのは `share/ghostty` ディレクトリそのもの**
  (`zig-out/share/ghostty`)。かつ libghostty は子プロセスへ `TERMINFO=<resources_dir>/../terminfo` を
  渡す(`src/termio/Exec.zig`)ため、**`ghostty/` と `terminfo/` が同じ親の下に兄弟として並んでいる配置が必須**。

  ```
  <root>/ghostty/     ← GHOSTTY_RESOURCES_DIR に設定する
  <root>/terminfo/    ← 兄弟。ここが無いと TERM=xterm-ghostty を引けない
  ```

  `Spikes/gate1/scripts/build-app.sh` は `.app/Contents/Resources/{ghostty,terminfo}` にこの構造を作る。
- **PoCアプリ側で `GHOSTTY_RESOURCES_DIR` を設定する必要がある。** ここを飛ばすと `TERM=xterm-ghostty` の terminfo が引けず、TUI(= Claude Code/Codex)の挙動検証が最初から歪む。M1 の必須項目とする。

### 4.6 iOS に関する重大な変更(Gate 2 への影響 — 本Gateの範囲外だが記録)

`src/build/Config.zig` (main) にビルド時エラーが追加されている:

> "iOS is not a supported target for the full Ghostty build; only libghostty-vt supports iOS (`-Demit-lib-vt`)"

さらに `osVersionMinLibVt` のコメント: "lib-vt is the only thing we still build for iOS"。

一方 **タグ `v1.3.1` の `GhosttyXCFramework.zig` には `ios` / `ios_sim` スライスの生成が残っている**。
つまり **iOS 向け完全版 libghostty のサポートは v1.3.1 以降、upstream main で削除された**。

- Gate 2(§24「iPad/iPhone Terminal: SwiftNIO SSH → tmux attach → libghostty描画」)の前提、および §21.2 全体図の「iPhone/iPad: libghostty-based TerminalRenderer candidate」は、**upstream main では現在成立しない**。
- v1.3.1 にピン留めすれば当面は iOS スライスを作れるが、upstream の更新を受け取れなくなる。
- **これは設計判断を要する事項であり、本スパイクでは判断しない。** ユーザーへ報告し、`docs/architecture.md` §24/§25 の扱いは別途決めてもらう。

### 4.7 ピン留め方針(提案、要ユーザー確認)

| 案 | ref | zig | 長所 | 短所 |
|---|---|---|---|---|
| A | `v1.3.1` | 0.15.2 | 安定タグ。iOSスライスが残る(Gate 2 の道を閉じない)。libghostty-spm と同一ベースなのでプリビルドと比較検証できる | upstream の最新変更・修正を受け取れない |
| B | `main` の特定 commit | 0.16.0 | 最新。Xcode 26 前提が手元環境と一致 | API変動を直に受ける。iOS 完全版が使えない |

**PoC の推奨は A(v1.3.1 ピン)**。理由: Gate 1 の目的は「libghostty で必要な品質が出るか」であり、最新追随の検証ではない。
かつ A なら Gate 2 の可否を同じ xcframework で続けて試せる。**ただしこれは提案であり、確定ではない。**

### 4.8 ライセンス確認

| 対象 | ライセンス | 確認方法 | 判定 |
|---|---|---|---|
| ghostty-org/ghostty | **MIT** | GitHub API `license.spdx_id` = `MIT`(2026-08-31 確認) | §23 の permissive 方針に適合 |
| libghostty-spm | MIT(同梱バイナリは Ghostty 由来、テーマは iTerm2-Color-Schemes の MIT) | README | 適合。ただし §4.3 の注記 |
| Termini | MIT | README | 適合。ただし §4.3 の注記 |

- ghostty の transitive dependency(libxev、vaxis、fontconfig/freetype/harfbuzz 系、oniguruma 等)は **未監査**。配布前に `build.zig.zon` の全依存を個別確認すること(§23「実際の配布前に、採用する固定versionと全transitive dependencyを再確認する」)。**PoC段階では未監査のまま進めてよいが、Gate 1 の合格条件には「依存監査が現実的に可能である」ことを含める。**
- ブランディング(§23.3): PoC アプリ名に Ghostty 由来の名称・アイコンを使わない。`Spikes/gate1` 配下の暫定名で十分。

### 4.9 先行事例(参考にできる、コードはコピーしない)

§23.1「既存プロジェクトのコードを『参考』と称してコピーしない」に従い、**実装アプローチの存在証明としてのみ**扱う。

| プロジェクト | 内容 |
|---|---|
| Muxy (https://github.com/muxy-app/muxy) | SwiftUI + libghostty の macOS ターミナル多重化。`scripts/setup.sh` で GhosttyKit.xcframework を取得 → `swift build` → `swift run`。macOS 14+ / Swift 6.0+。MIT。**tmux は使わず自前で多重化している**(我々とは逆方針) |
| conterm / Enso / justty / macterm | いずれも libghostty ベースの macOS ターミナル。SwiftUI 実装例が複数存在する |
| awesome-libghostty (https://github.com/Uzaaft/awesome-libghostty) | 上記のカタログ |
| Kytos (jwintz) | Ghostty ベースの native macOS ターミナルに関する解説記事。URL が認証リダイレクトで取得できず未読 |

**判断材料としての意味:** 「SwiftUI + libghostty で実用ターミナルが複数出荷されている」= Gate 1 の M1〜M3 は技術的に到達可能性が高い。
未知が大きいのは **libghostty + tmux の組み合わせ**(先行事例が薄い)と **長時間稼働/大量出力**(誰も公表していない)。

---

## 5. マイルストーン分割

各マイルストーンは「§24 のどのチェック項目を潰すか」で定義する。**M1 が通らなければ M2 以降に進まない。**

### M0. 準備(0.5日想定)

- [ ] zig インストール(ピン留め ref に対応する版。案A なら `brew install zig@0.15`)
- [ ] `sudo xcode-select --switch /Applications/Xcode.app` の確認
- [ ] ghostty を `Spikes/gate1/vendor/ghostty` に clone + ピン留め ref を checkout(**submodule にしない**。スパイクは本体に持ち込まない前提)
- [ ] `tmux -V` / `claude --version` / `codex --version` を記録
- [ ] `zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast` を通す
- [ ] `zig-out/macos/GhosttyKit.xcframework` と `zig-out/share/` の生成を確認

**Gate 1 項目:** なし(前提整備)
**打ち切り条件:** ビルドが2日以内に通らない場合、原因(zig版・SDK・Metal Toolchain・依存取得)を記録して §4.3 のプリビルド版へ切り替え、ビルド可否は別途の課題として分離する。

### M1. libghostty を SwiftUI ウィンドウに載せ、zsh を動かす

- [ ] SwiftPM または最小 Xcode プロジェクトで `GhosttyKit.xcframework` をリンク(`import GhosttyKit`)。Carbon / Metal 等の必要な linker flag を特定して記録
- [ ] `GHOSTTY_RESOURCES_DIR` を設定し、`TERM=xterm-ghostty` の terminfo が引けることを確認(`infocmp` / `tput` で検証)
- [ ] `ghostty_init` → config → `ghostty_app_new`(runtime callbacks 実装) → `NSView` を用意 → `ghostty_surface_new`
- [ ] `NSViewRepresentable` で SwiftUI ウィンドウに埋め込み、`ghostty_app_tick` / `ghostty_surface_draw` を run loop に接続
- [ ] `command` に `/bin/zsh` を指定して対話シェルが動く
- [ ] ウィンドウリサイズで `set_size` / `set_content_scale` が正しく反映され、`ghostty_surface_size()` の columns/rows が追随する
- [ ] Retina / 外部ディスプレイ間の移動(`set_display_id`、scale factor 変化)
- [ ] **AppKit bridge の範囲を明文化する**: SwiftUI だけで済む部分／`NSView` サブクラスが必須の部分(key events、`NSTextInputClient`、mouse tracking、first responder、menu)を一覧化

**Gate 1 項目:** Metal描画とresize、AppKit bridgeが必要な範囲、VT互換性(基礎)
**成果物:** `Spikes/gate1/M1-findings.md`(ビルド手順の実際、linker flag、AppKit bridge 一覧、`TerminalRenderer` protocol に必要となる操作の候補)

### M2. tmux attach と split / zoom / detach

- [ ] surface の `command` を `tmux new-session -A -s <name>` にして attach
      (実施時のセッション名は **`gate1-spike`** 固定。ユーザーの既存 tmux セッションには触らない)
- [ ] tmux 内での split / zoom / pane 移動が期待どおり動く(prefix キーが libghostty のキーバインドに食われないか)
- [ ] detach → 再 attach で状態が保たれる
- [ ] tmux の mouse mode(`set -g mouse on`)で pane 選択・リサイズ・スクロールが効く(mouse protocol)
- [ ] copy-mode でのスクロール、`ghostty_surface_has_selection` / `read_selection` によるアプリ側選択との衝突有無
- [ ] copy / paste(⌘C / ⌘V、bracketed paste、複数行貼り付け)
- [ ] URL / path の hit testing(`GHOSTTY_ACTION_MOUSE_OVER_LINK` / `OPEN_URL` の挙動、tmux 経由でも OSC 8 が通るか)
- [ ] **同一 tmux session に Ghostty.app と PoC アプリを同時 attach**(§4.2 複数端末接続の確定仕様の予行)
- [ ] ~~`ghostty_surface_foreground_pid` / `tty_name` が tmux 越しに何を返すか記録~~
      → **v1.3.1 に両関数とも存在しない**(§4.4 訂正)。代わりに `tmux list-panes` / `list-clients` で
      pane・クライアント・プロセスがどこまで特定できるかを記録する(Gate 3 の前哨)
- [ ] app 側から `tmux split-window` 等の **CLI 操作**を叩いたとき、surface の表示が即時追随するか
      (本体設計 §21.3 は「tmux を CLI で扱う」方針であり、ここが成立しないと操作 API が作れない)

**Gate 1 項目:** tmux split／zoom／attach／detach、mouse protocol、copy／paste・selection・URL/path hit testing
**成果物:** `Spikes/gate1/M2-findings.md`(tmux 版数、キーバインド衝突一覧、Gate 3 への申し送り)

### M3. Claude Code / Codex の TUI 実動 + 日本語・IME・絵文字

- [ ] tmux 内で Claude Code を起動し、通常操作(プロンプト入力、ツール実行、権限確認、Ctrl-C、履歴スクロール)が本家 Ghostty.app と同等に動く
- [ ] 同じことを Codex CLI でも確認(§12「Agent非依存」方針上、片方だけの確認は不可)
- [ ] 日本語入力: macOS 標準日本語IMEで `preedit` 表示、変換候補ウィンドウ位置(`ghostty_surface_ime_point`)、確定、変換中の Enter / Esc
- [ ] 日本語表示: 全角幅、行折り返し、tmux の pane 境界での欠け
- [ ] 絵文字・grapheme cluster: ZWJ 合字、肌色修飾、Variation Selector、幅計算とカーソル位置ずれ
- [ ] TUI の再描画: リサイズ中、Drawer 開閉相当の幅変更、フルスクリーン切り替え
- [ ] Claude Code の質問／権限プロンプト時の表示崩れがないか(§11 質問UIの前提)

**Gate 1 項目:** VT互換性、IME・日本語入力・絵文字・grapheme width
**成果物:** `Spikes/gate1/M3-findings.md`(Ghostty.app との差分表。差分があれば「埋め込み方の問題」か「libghostty の問題」かの切り分け結論を必ず書く)

### M4. 大量出力・長時間稼働・メモリ

- [ ] 大量出力: `yes`、巨大ログの `cat`、`find /`、ビルドログ相当。描画が詰まらないか、入力応答が保たれるか
- [ ] 高速更新 TUI: `top`、`htop`、進捗バー
- [ ] スクロールバック上限の挙動とメモリ増加
- [ ] 長時間稼働: 8時間以上の連続稼働で RSS の推移を記録(`ghostty_app_tick` を回し続ける前提)
- [ ] 複数 surface 同時(§2 の「1タスク=1タブ」を想定して 5〜10 surface)を開いた時のメモリと CPU
- [ ] surface の生成／破棄を繰り返してリークがないか(`ghostty_surface_free`)
- [ ] スリープ／復帰、外部ディスプレイ抜き差し、アプリの background / foreground 復帰

**Gate 1 項目:** 大量output、長時間稼働、memory
**成果物:** `Spikes/gate1/M4-findings.md`(実測値。閾値ではなく生データを残す)

### 総括

- [ ] `Spikes/gate1/RESULT.md` に Gate 1 の合否判断材料をまとめる
- [ ] `TerminalRenderer` protocol の暫定シグネチャ案を、M1〜M4 で実際に必要になった操作から逆算して起こす(§21.5 の隔離境界の実証)
- [ ] `docs/architecture.md` への反映が必要な項目を**リストアップするだけ**にとどめ、更新はユーザー判断を仰ぐ

---

## 6. 設計上の論点(PoC で確認し、判断はユーザーへ返す)

### 6.1 libghostty の split と tmux の split が二重になる

`ghostty.h` には `ghostty_surface_split`、`ghostty_surface_split_focus`、`ghostty_surface_split_resize`、`ghostty_surface_split_equalize`、`GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM` などがある。
一方 §4.1(確定)では **pane 分割は tmux の責務**であり、アプリは split/close/select/zoom の最小操作しか公開しない。

→ **PoC では libghostty 側の split 機能を一切使わず、1 surface = 1 tmux attach で通す。**
libghostty の split 系 action が飛んできた場合にどう握り潰すか(キーバインド無効化 or action 無視)を M2 で確認して記録する。

### 6.2 ホストから PTY へ生バイトを書く API がない

`ghostty.h` の入力経路は `ghostty_surface_key` / `ghostty_surface_text` / `ghostty_surface_preedit` のみで、
「任意のバイト列を子プロセスの PTY へ書く」関数は見当たらない(§4.4)。

これは §9.2「Diff review コメントを実装 agent の pane へ送る」や §10「Ask Agent」の実装方式に影響する。

- 素直な解: **`tmux send-keys` を使う**。tmux が pane を持っているので、アプリは tmux CLI 経由でテキストを注入できる。これは §21.3「tmux を CLI で扱う」方針と整合する。
- 代替: `ghostty_surface_text` を叩いて「ユーザーが打った」ことにする。フォーカス依存で脆い。

→ M2 で `tmux send-keys` によるテキスト注入(改行・複数行・特殊文字のエスケープ)を試し、実現可能性を記録する。**方式の決定はしない。**

### 6.3 surface 単位で得られるプロセス情報

`ghostty_surface_foreground_pid` / `ghostty_surface_tty_name` は Gate 3(Agent Adapter)にとって魅力的だが、
tmux を挟むと surface の foreground process は `tmux` クライアントになる可能性が高い。
→ M2 で実測し、Gate 3 では別途 `tmux list-panes -F '#{pane_pid}'` 系が必要かを申し送る。

> **訂正(M0 実測): この 2 関数は v1.3.1 に存在しない**(§4.4 の訂正を参照)。
> したがって「tmux を挟むと何が返るか」を測る対象自体が無く、`tmux list-panes` 系の利用は
> 選択肢ではなく**前提**になる。M2 では tmux CLI 側で何が取れるかを記録する。

---

## 7. 撤退基準(Gate 1 不成立と判断する条件)

§24「PoC後の判断」に従い、**Gate 1 が不成立なら UI 全体の実装へ進む前に Terminal renderer 候補を再評価する**。
本スパイクは「不成立かどうかの材料」を出すところまでを担い、**再評価そのものは行わない**。

以下のいずれかに該当したら、Gate 1 を「不成立」または「条件付き」として報告する。

### 致命(即不成立)

1. **`GhosttyKit.xcframework` を upstream から自力ビルドできない**(zig / SDK / 依存取得の問題が解消不能)。第三者プリビルドへの永続依存は §23 の方針上、本採用の前提にできない。
2. **Claude Code / Codex の TUI が実用にならない**(表示崩れ、キー入力の取りこぼし、質問／権限プロンプトが読めない)。Agent Terminal が主 UI である以上(§5 確定)、これは製品が成立しない。
3. **日本語 IME が実用にならない**(preedit が出ない、候補ウィンドウ位置が取れない、確定が壊れる)。日本語利用が前提のプロジェクトであり、回避策がない。
4. **tmux attach 下で split / zoom / detach / mouse が壊れる**。§4.1 の確定モデルが tmux 前提であり、代替手段がない。
5. **ライセンス上の障害**(transitive dependency に copyleft や不明ライセンスが混在し、除去も置換も不可能)。§23 で例外承認制。

### 重大(条件付き。回避策とコストを添えて報告)

6. 大量出力で入力応答が失われる、または長時間稼働で RSS が単調増加し実用時間内に破綻する。
7. AppKit bridge の必要範囲が大きすぎ、「SwiftUI + 必要最小限の AppKit」(§21.1)と言えない規模になる。
8. API 非安定性が実害として現れる(ピン留めを外すと壊れ、追随コストが継続的に高い)。
9. `TerminalRenderer` protocol による隔離(§21.5)が成立しない — libghostty 固有概念がアプリ全体へ漏れる設計しか作れない。

### 不成立時の代替候補(**列挙のみ。採用判断はユーザー**)

設計書に既に記載のあるもの:

- §21.6「Rust Core + Swift UI」— 次点、未採用
- §21.6「Tauri + xterm.js」— 未採用(Terminal品質目標で劣る可能性)

本調査で新たに判明した第三の道(**設計書に未記載。記録のみ**):

- **libghostty-vt(パーサ + terminal state)+ 自前 Metal レンダラ + 自前 PTY**。
  libghostty-vt は C API とサンプルが整備され、macOS/iOS/Linux/Windows/Wasm 対応、`swift-vt-xcframework` の Swift サンプルもある。
  VT互換性という最も難しい部分だけを借り、描画・入力・PTY を自前で持つ構成。
  iOS が完全版 libghostty から外れた(§4.6)ことを踏まえると、**iOS を諦めない場合の現実的な選択肢になりうる**。
  ただし描画・入力・IME・selection をすべて自作することになり、工数は大幅に増える。
  → **この案の是非は本スパイクでは判断しない。** Gate 1 の結果と併せてユーザーへ提示する。

---

## 8. リスクと不明点

| # | 内容 | 影響 | 現時点の扱い |
|---|---|---|---|
| R1 | **libghostty の埋め込み API は公式に非安定**。「macOSアプリ専用の内部境界」であり、汎用埋め込み向けに安定化されていない | 本採用後も upstream 追随コストが継続。破壊的変更を随時受ける | ピン留め運用(§4.7)で緩和。§21.5 の renderer 隔離が保険として機能するかを M1 で実証 |
| R2 | **リポジトリに完全版 libghostty の埋め込みサンプルが存在しない**(`example/` は全て vt 系)。唯一の参照実装が `macos/` の Ghostty.app 本体 | 学習コストが高い。Ghostty.app のコードを読むことになるが §23.1 によりコピー不可、clean-room 実装が必要 | M1 の工数を厚めに見積もる。読解と実装のログを残す |
| R3 | **iOS が完全版 Ghostty ビルドから除外された**(main)。v1.3.1 には残存 | Gate 2 および §21.2 全体図の前提が崩れる可能性 | **設計判断事項としてユーザーへ報告**。本スパイクでは判断しない |
| R4 | **libghostty + tmux の組み合わせの先行事例が乏しい**(Muxy 等は tmux を使わず自前多重化) | M2 が最も読めない。キーバインド衝突、mouse protocol、selection の二重管理 | M2 を独立マイルストーンとして早期に置く |
| R5 | 長時間稼働・大量出力のデータが公開情報に存在しない | M4 まで判明しない | M4 を必ず実施。M3 までの成功で楽観しない |
| R6 | ghostty の transitive dependency のライセンス未監査 | 配布段階で判明すると手戻りが大きい | Gate 1 合格条件に「依存監査が現実的に可能」を含める。監査自体は別タスク |
| R7 | `GHOSTTY_RESOURCES_DIR` / terminfo の扱いを誤ると TUI 検証が最初から歪む | M3 の結論が信用できなくなる | M1 の必須チェック項目に格上げ済み |
| R8 | Apple Silicon 実機のみ。x86_64 は未検証 | Intel Mac 対応が必要なら別途検証が要る | 対応方針が未確定。§25 の「対応OSの初期version」と併せてユーザー判断 |
| R9 | `ghostty_runtime_config_s` の全フィールド、action payload の詳細、スクロールバック取得 API の有無が未確認 | M1 の見積もりが振れる | M1 でヘッダを読み切って本文書へ追記 |
| R10 | tmux 版数を未計測。tmux の版差で mouse / copy-mode 挙動が変わる | M2 の再現性 | M0 で記録 |
| R11 | Kytos の記事(認証リダイレクトで未読)に有用な知見がある可能性 | 小 | 必要なら別経路で再取得 |

---

## 9. 参照

- Ghostty repository — https://github.com/ghostty-org/ghostty (MIT)
- libghostty C API Overview — https://ghostty-org-ghostty.mintlify.app/api/overview
- libghostty API Reference (tip) — https://libghostty.tip.ghostty.org/
- "Libghostty Is Coming" (Mitchell Hashimoto) — https://mitchellh.com/writing/libghostty-is-coming
- awesome-libghostty — https://github.com/Uzaaft/awesome-libghostty
- libghostty-spm — https://github.com/Lakr233/libghostty-spm
- Termini — https://github.com/arach/Termini
- Muxy — https://github.com/muxy-app/muxy
- 本プロジェクト設計書 — `docs/architecture.md` §21.1 / §21.5 / §21.6 / §23 / §24
