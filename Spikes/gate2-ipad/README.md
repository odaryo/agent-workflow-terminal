この文書は計測の記録であり、`docs/architecture.md` の状態区分は変更しない。

# Gate 2 iPad スパイク

## 目的

設計書 §20.6・§24 の現在の推奨である SwiftUI + SwiftTerm + Citadel を、
iPad 実機から Tailscale 上の SSH → Host の tmux attach で測る。
使い捨てコードであり、lint・format・テスト・CI の対象外。本体へコピーしない。
この段階は接続と端末の計測用アプリを用意する。実機の操作・結果記入・採否の判断はユーザーと Director が行う。

## 環境

- Director の事前計測 (2026-11-10): Xcode 27.2 (27B52)、Swift 6.4.2、iOS SDK 27.2。
- iPad Air 13-inch (M3)、iPadOS 27.0.1。deployment target は iOS 18.0、アプリは Swift 5 モード。
- Host: Mac、ログインシェル `/bin/zsh`、tmux 3.8 (`/opt/homebrew/bin/tmux`)。
- XcodeGen 2.46.0 (MIT)、Personal Team の無料署名。
- バンドル ID は段階0と同じ `dev.odaryo.awt.spike.gate2ipad`。team はファイルに固定しない。
- 組み込み依存: Citadel 0.12.1 (MIT)、SwiftTerm v1.99.3 (MIT)。直接依存の版は `project.yml` で固定する。
- Citadel の推移依存: Wellz26/swift-nio-ssh (`0.3.4..<0.4.0`、Apache-2.0、Joannis のフォーク由来)、
  swift-nio、swift-log、swift-crypto (Apache-2.0)、BigInt、ColorizeSwift (MIT)。
  SwiftTerm の manifest には swift-argument-parser、swift-docc-plugin、swift-png (いずれも Apache-2.0) もある。
  実際に解決された推移依存の版は Director が生成・ビルドした `.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` を証拠として保管する。
  tmux は Host の外部 CLI。依存ソースはこのディレクトリへ複製していない。

段階0の署名・導入・起動の実測は [Issue #789 の段階0コメント](https://github.com/odaryo/agent-workflow-terminal/issues/789#issuecomment-6759027077) を参照。
同コメントの Xcode / SDK 26.5 表記は [訂正コメント](https://github.com/odaryo/agent-workflow-terminal/issues/789#issuecomment-6759053865) により 27.2 に訂正済み。
7日間のプロファイルと初回の検証・入れ直しは段階0の記録にある。期限後の挙動はまだ測っていない。

## 準備

1. Host の「システム設定 > 一般 > 共有 > リモートログイン」を有効にし、接続するユーザーを許可する。
2. Host と iPad で Tailscale に接続し、Host の Tailscale IP または MagicDNS 名を確認する。
   本アプリは通常の SSH サーバーへ機器の鍵で認証する。Tailscale は到達経路として使う。
   Tailscale SSH 自体の利用可否はこの段階では判定しない。
3. Xcode の Accounts に Apple ID / Personal Team を登録する。USB 接続した iPad の信頼と Developer Mode を有効にする。
4. 初回は次でプロジェクトを生成し、2種類の機器 ID を調べる (ユーザーまたは Director が実行)。

   ```bash
   cd Spikes/gate2-ipad
   xcodegen generate
   xcodebuild -project Gate2iPad.xcodeproj -scheme Gate2iPad -showdestinations
   xcrun devicectl list devices
   ```

5. リポジトリ直下から次を実行する。スクリプトは生成 → Debug ビルド → 導入 → 起動を行う。
   環境変数が1つでも空なら、調べ方を表示して処理を始めず終了する。

   ```bash
   export AWT_DEVELOPMENT_TEAM='<Personal Team の Team ID>'
   export AWT_IPAD_XCODEBUILD_ID='<showdestinations の id>'
   export AWT_IPAD_DEVICECTL_ID='<devicectl の Identifier (UUID)>'
   Spikes/gate2-ipad/scripts/build-install.sh
   ```

   DerivedData はこのディレクトリ内の `DerivedData/`。生成した `.xcodeproj/` とビルド成果物は追跡しない。

   **初回のビルドで詰まった2点** (2026-11-10、Xcode 27.2):
   - `Could not resolve package dependencies: …/org.swift.swiftpm/manifests/ManifestLoading already exists in file system`
     で依存解決が止まった。原因は `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading` に残っていた空のロック
     ファイル (11/1 に途中で終わった `swift build` / `swift test` の残り。同じ時刻の「A Document Being Saved By swift-build」
     ディレクトリも残っていた)。`xcodebuild -packageCachePath` を指定しても、この場所は変わらなかった。`lsof` で開いて
     いるプロセスが無いことを確かめてから別の場所へ移すと、解決が通った。
   - 次に `Validate plug-in "SwiftTermBuildInfoPlugin" in package "swiftterm"` で止まった。SwiftTerm のビルドプラグインは
     初回に利用者の承認が要る。Xcode で `Gate2iPad.xcodeproj` を開き、実行先をシミュレータの iPad にして ⌘B を押し、
     Issue ナビゲータ (⌘5) の「Plugin "SwiftTermBuildInfoPlugin" from package "SwiftTerm" must be enabled before it can be
     used」を選んで「Trust & Enable」を押すと、以後はコマンドラインのビルドも通った。プラグインは SwiftTerm 自身の
     ディレクトリで読み取りだけの git (`branch --show-current` / `describe` / `rev-parse HEAD` / `status --porcelain`) を
     実行し、版の情報と XTGETTCAP の表を生成するだけである (v1.99.3 のソースで確認)。`-skipPackagePluginValidation` は
     使っていない。
   初回の起動で開発者の信頼が求められたら、iPad の「設定 > 一般 > VPN とデバイス管理」で信頼・検証する。
   段階0で起動できるまでに行った入れ直しの記録は上記コメントを参照。

6. アプリに表示される公開鍵をコピーし、Host の接続ユーザーの `~/.ssh/authorized_keys` へ1行で追記する。
   既存の行は保持する。`~/.ssh` は 700、`authorized_keys` は 600 にする。
   秘密鍵は初回起動時に生成し、Keychain の `AfterFirstUnlockThisDeviceOnly` で同期せず保存する。
   公開鍵の base64 は SSH wire 形式 (長さ付き `ssh-ed25519` + 長さ付き32バイト公開鍵)。
7. host、port (既定22)、user、tmux の絶対パスを入力する。設定は UserDefaults に自動保存される。
8. 「接続して session 一覧を更新」で初回の host key 指紋が出る。Host 上で次などを実行し、
   **実際に提示された鍵と同じ種類**の SHA256 指紋を確認してから「この鍵を承認して再接続」を押す。

   ```bash
   for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key" -E sha256; done
   ```

   未承認の接続は認証前に失敗させる。承認した wire 形式の鍵を host:port ごとに UserDefaults へ保存する。
   鍵が変わると拒否し、保存済みと今回の指紋を両方表示する。
   正当な変更だと Host 上で確認できた場合は、一度 session 一覧画面へ戻り、対象 host:port の保存した鍵を削除してから再接続する。

## 計測の流れ

1. Host で実験用の既存 tmux session を用意する。Host 側でも同じ session に attach し、
   使用中の tmux の版、session 名、window-size 設定、接続前の端末サイズを記録する。
2. アプリで一覧を更新し、対象 session を選ぶ。新規 session の作成や終了操作はアプリには無い。
   PTY は `xterm-256color`、SwiftTerm の現在の cols / rows で要求する。サイズ変更は window-change で送る。
3. Citadel 0.12.1 の公開 `withPTY` は PTY 要求後に shell を要求する。
   PTY と exec を組み合わせる公開 API は確認できなかったため、shell に
   `exec '<tmux の絶対パス>' attach-session -t '=<session 名>'` と改行を送る。
   パスと session 名の単一引用符は shell 用にエスケープする。Host の shell 起動設定の影響も計測対象となる。
4. shell、Claude Code、Codex の実際の TUI で下表の操作を行う。
   キーボード・IME・選択・クリップボード・スクロール・マウス処理は SwiftTerm の既定に任せている。
   OSC 52 などの delegate の既定動作も変更していない。画面のコピー操作とは分けて結果を記録する。
5. 画面回転、ソフトウェアキーボードの開閉、iPad の画面サイズ変更で cols / rows が追従するか確認する。
6. background へ移すと channel と SSH 接続を閉じ、active 復帰時は選択中の同じ session へ再接続する。
   通信が切れた場合は状態表示と「再接続」で戻れるか確認する。tmux session 内のプロセス継続も Host で確認する。
7. `window-size smallest` は Host 側で対象の実験用 window に設定して測る。
   接続前、iPad attach 中、iPad background / 一覧へ戻る操作で detach した後の Host の表示とサイズを比較する。
   既存の設定値を記録し、計測終了後に戻す。アプリは tmux の設定を変更しない。
8. 「接続ログ」を展開し「ログ全文をコピー」で生ログを保存する。接続・認証・attach 要求・切断・再接続を時刻付きで記録する。
   attach 要求送信は tmux の attach 成功を保証するイベントではないため、端末画面と Host の状態も証拠にする。
   ログはアプリ実行中のメモリに保持し、アプリ終了前にコピーする。
9. 各証拠に日時、ネットワーク、入力機器、対象 TUI / 版、再現操作を添え、下表に所在を記入する。

## 結果

[Issue #789 の完了条件](https://github.com/odaryo/agent-workflow-terminal/issues/789) の9項目。
空欄は未計測。結果はユーザーと Director が実機確認後に記入する。

| 手順 | 結果 (✅/⚠️/❌/❓) | 生の結果・証拠の所在 |
| --- | --- | --- |
| 日本語 IME: ソフトウェア / 外付けキーボードそれぞれで変換中表示、確定、候補窓を確認 | ⚠️ | 2026-11-10、iPadOS 27.0.1、日本語かな入力。**外付け・画面のキーボードとも、変換中の文字が端末に表示されない**。候補窓は出て、候補を選ぶ・確定すると文字は正しく入る。ユーザーの評価は「変換中の文字が見えないので使いづらい」。原因は SwiftTerm 1.99.3 の iOS 版が marked text を `textInputStorage` に保持するだけで描画しないこと (`Sources/SwiftTerm/iOS/iOSTextInput.swift` の `setMarkedText`。同ファイル冒頭のコメントに「setMarkedText could show an overlay of the text being composed」と未実装の案として書かれている)。画面のキーボードは、外付けキーボードの接続中は出ず、補助キーの列だけが出る (iPadOS の通常の挙動)。補助キーの列のキーボードボタンは SwiftTerm 独自の F キー・記号の画面と通常のキーボードを切り替える |
| 絵文字・全角の表示幅、true color、Claude Code / Codex の TUI 表示崩れを確認 | ✅ | 2026-11-10、`scripts/display-test.sh` を iPad の端末で実行。全角・半角カナ・絵文字・肌色修飾・国旗・ZWJ (家族)・異体字セレクタ付き ❤️ の各行で行末の `\|` がそろい、罫線も崩れず、true color の3本のグラデーションもなめらか (ユーザーの目視)。Claude Code は iPad から会話でき、表示崩れなし。Codex も iPad で起動して表示崩れなし (ユーザーの目視)。日本語入力は上の行と同じ |
| 外付けキーボードの Esc・Ctrl・矢印・⌘ の組み合わせが端末へ届くか確認 | ⚠️ | 2026-11-10、`scripts/key-test.sh` (届いたバイト列を16進で表示) を iPad の端末で実行。画面は `evidence/02-key-test-option-cmd.png` (追跡しない)。**届いた**: Esc `1b`、Ctrl-C `03`、Ctrl-A `01`、矢印 `1b 5b 41`〜`44`、Tab `09`、Ctrl+矢印 `1b 5b 31 3b 35 4x`、Shift+矢印 `1b 5b 31 3b 32 4x`、Option-B `1b 62`、貼り付け。**ずれた**: Option-Shift-B が `1b 62` (期待は `1b 42`。Shift が落ちる)。**届かない**: Option-← (何も出ない。iPadOS が文字入力の語移動として先に処理しているのか、SwiftTerm の `pressesBegan` の分岐で送られずに終わるのかは切り分けていない)。⌘-K も何も出ない (SwiftTerm は kitty キーボードプロトコルが無効の間、⌘ を含むキーを端末へ送らない。`iOSTerminalView.swift` 3275〜3279 行の設計どおり) |
| タッチのスクロール、選択、コピー・貼り付け、マウス・トラックパッドを確認 | ✅ | 2026-11-10、ユーザーの操作による。指のスワイプでスクロールできる。長押しで Paste のメニューが出て、Select を選ぶと範囲選択に入れる。貼り付けは長押しのメニューと ⌘-V の両方で端末へ届いた (`key-test.sh` で貼り付けた文字列のバイト列を確認)。トラックパッド・マウスのスクロールとクリックも効いた。スワイプで動くのが SwiftTerm 側の scrollback か tmux のコピーモードかは見分けていない |
| host key の初回承認・一致・不一致の拒否・削除と、機器の鍵による公開鍵認証を確認 | | |
| background / active での再接続・同一 session 再 attach、Wi-Fi / モバイル回線の切り替えを確認 | ✅ (回線が生きている間) | 2026-11-10、Wi-Fi、Tailscale 経由 (Host `100.108.213.118`)。アプリの接続ログ (UTC) による。**数分の background からの復帰では、同じ session へ自動で再 attach できた** (05:37:57 background → 05:40:20 再 attach、05:49:59 → 05:50:02)。**約10分以上 background にいた後は、TCP の接続段階で止まった**: 05:16:11 background → 05:26 の3回の接続は認証まで進まず、成功は 05:29:30。06:05:40 background → 06:11〜06:15 の5回はいずれも30秒で `NIOCore.ChannelError error 0` (認証より前)、成功は 06:21:50。**前面で使用中にも切れた**: 06:21:55 attach → 06:22:16 `ChannelError error 6`。その直後 (15:25 JST) の Mac 側では、`tailscale status` が iPad を `idle; offline, last seen 5m ago`、`tailscale ping` が応答なし、Mac のスリープ記録なし。ユーザーが iPad を確かめたところ、iPad のネットワークが止まっていた。つながらなかった時間帯はアプリではなく回線側の原因とみる (止まった理由は未確認)。Wi-Fi から iPhone のテザリング (モバイル回線) への切り替えも、ユーザーの操作で「問題なく出来た」(切り替えの瞬間に接続が保たれたのか、切れて再接続したのかは見分けていない) |
| window-size smallest で iPad attach 中の Mac の見え方と detach 後の復元を確認 | ✅ | 2026-11-10、tmux 3.8、session `awt-agent-workflow-terminal-03b8ac7b-2` (アプリが current window に `window-size smallest` を設定済み。グローバルは `latest`)。Mac 側の `tmux display-message` / `list-clients` で測った。接続前 window 191×63 (Mac の Ghostty クライアント 191×64)。iPad attach 中 (15:44:21 JST) は window **180×53**、クライアントは Mac 191×64 `xterm-ghostty` と iPad 180×54 `xterm-256color` の2つ。iPad で「session 一覧へ」を押して切断した後 (15:44:48) は window 191×63、クライアントは Mac だけに戻った。Mac 側の表示もユーザーの目視で、iPad 接続中に tmux の表示が小さくなり、切断後に戻ったことを確認 |
| Personal Team 署名の実際の期限と期限後の入れ直しの手間を記録 (段階0の記録も参照) | | |
| 上記を根拠に SwiftTerm をそのまま使えるか判定し、不成立なら次の候補を提示 | ⚠️ 判定案 (決定はユーザー) | 下の「SwiftTerm の判定案」を参照 |

## SwiftTerm の判定案

**「そのまま」では使えない。手当て2つを条件に、SwiftTerm を使い続けるのが案である。** 表示 (幅・色・Agent の TUI)、
Esc・Ctrl・矢印、タッチとトラックパッド、貼り付け、`window-size smallest` との組み合わせ、裏へ回したときの再 attach は、
手を入れずに通った。毎日の操作で困るのは次の2つで、どちらも SwiftTerm の iOS 版の入力処理にある。

1. **日本語の変換中の文字が見えない** (外付け・画面のキーボードとも)。SwiftTerm は marked text を保持するが描かない。
   `setMarkedText` は `extension TerminalView: UITextInput` の中の `public func` で、`open class TerminalView` の
   派生クラスからは上書きできない。手当ては (a) SwiftTerm に描画を足す (上流への修正の提案、または MIT のフォーク)、
   (b) アプリ側に入力欄を別に設け、変換はそこで行い、確定した文字だけを端末へ送る、のどちらか。
2. **Option-← が届かず、Option-Shift-B の Shift が落ちる**。`pressesBegan` は `open override` なので、アプリ側の
   派生クラスで正しいバイト列を送り直せる見込み。ただし Option-← が `pressesBegan` まで届いているか
   (iPadOS が文字入力の語移動として先に使っていないか) は確かめていない。届いていなければ、`UIKeyCommand` で拾う形になる。

手当てが成り立たない場合の次の候補は、**libghostty を iOS でも使う案**である。macOS の `TerminalRenderer` として
確定済みで (設計書 §21.5)、Gate 1 では macOS で preedit の描画を確かめている (実際のかな漢字変換の操作は Gate 1 でも
未検証のまま)。iOS 向けにビルドして組み込めるかは、このスパイクでは調べていない。

SSH 側 (Citadel 0.12.1) は、公開鍵認証・host key の TOFU・PTY・window-change が問題なく動いた。前面に戻ったときの
自動の再 attach も回線が生きていれば通った。一方、使用中に接続が切れたとき (06:22) は自動では戻らず「再接続」を
押す必要があり、回線が止まっている間は接続のたびに30秒待って失敗した。§20.6 の「SSH の接続性が悪ければ Mosh を
検討する」を判断するときの最初の材料になる (今回の切断は回線側の停止によるもので、SSH の弱さとは言えない)。
本採用の前に判断が要るのは、Citadel が SSH の中核に個人のフォーク `Wellz26/swift-nio-ssh` (解決された版は 0.3.7、
Apache-2.0、star 0) を使っている点と、pty-req と exec を組み合わせる公開 API が無いため shell に
`exec tmux attach-session` を書き込んでいる点である。

この判定案は `docs/architecture.md` の状態区分を変えない。SwiftTerm と Citadel は §20.6 の「現在の推奨」のままである。

実装側の作成物と API 確認の記録は [RESULT.md](RESULT.md) に記載する。
