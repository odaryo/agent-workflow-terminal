#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: scripts/verify-app-ui.sh <サブコマンド> [引数...]

App/ の UI 配線を実機で確認するためのハーネス。CLAUDE.md「Development pipeline」の
「UI 配線は動かして確認する」で使う。

  build                 scripts/build-app.sh で最終バンドルを作る
  launch [--project P]  最終バンドルを起動し、ウィンドウを既定の大きさに整える
  activate              アプリを前面に出し、実際に前面になったことを確認する
  texts                 全ウィンドウの AX 要素を role と4種の文言属性付きで1要素1行に出す
  find <文字列> [--exact] [--role AXRole]
                        AX の文言に最初に一致する要素の "x y w h" を出す (既定は部分一致)
  click <x> <y>         activate 後、座標上のアプリを確認して実 HID クリックを送る
  click-text <文字列> [--exact] [--role AXRole]
                        find した要素の中心を activate してから click する
  right-click <x> <y>   click と同じ確認をしてから実 HID の右クリックを送る
  right-click-text <文字列> [--exact] [--role AXRole]
                        find した要素の中心を activate してから right-click する
                        (開いたメニューは texts の AXMenuItem で読み、Esc で閉じる)
  expect <文字列> [--exact] [--role AXRole]
                        find で見つかれば成功、無ければ失敗 (Overview の行・ボタン・sheet も対象)
  type <文字列>          今フォーカスがある所へ打鍵する (改行は拒否する)
  focused               フォーカスを持つ要素の role / description / value を出す
  value <部分文字列>     フォーカス中の要素の値にその文字列があれば成功、無ければ失敗
  quit                  起動したアプリを終了する
  selftest [--no-build] 行選択が効くところまでを1コマンドで通す (ハーネス自身の動作確認)
                        実行ごとに /private/tmp/awt-ui-verify/<$PWD の basename>/selftest.XXXXXX へ
                        使い捨てのリポジトリと Application Support を作り、終わったら socket 上の
                        その Project の session とともに消す。AWT_UI_APPLICATION_SUPPORT_DIR は
                        無視する (前回までに登録した Project を引き継がないため)
  -h, --help            このヘルプを表示

launch の Application Support は /private/tmp/awt-ui-verify/<$PWD の basename>/application-support。
AWT_UI_APPLICATION_SUPPORT_DIR で上書きできる。同じ worktree の再起動でも保存内容を残す。
launch の tmux socket 名は awt-ui-verify。AWT_UI_TMUX_SOCKET_NAME で上書きできる。
launch は最終バンドルを /private/tmp/awt-ui-verify/<$PWD の basename>/ へ写し、bundle id を
dev.local.agentworkflowterminal.ui-verify.<$PWD の basename> に変えて署名し直してから起動する。
UserDefaults は bundle id の domain に入るので、worktree ごとに分かれ、開発版のバンドル
(dev.local.agentworkflowterminal) と日常利用のアプリ (….user) の設定には触れない。
新しい bundle id では、通知の許可を初めて求める。
session は env -u TMUX tmux -L <名前> list-sessions で観測する。

検索対象: AXTitle / AXValue / AXDescription / AXAttributedDescription。
texts の各文言は引用符付きで、改行などはエスケープして出す。

**必ず最終バンドル (scripts/build-app.sh の出力) を対象にすること。** probe ビルドで
確認した結果を完了報告に使わない。
EOF
}

APP_NAME="AgentWorkflowTerminalApp"
SELFTEST_SCRATCH=""
SELFTEST_PROJECT=""
SELFTEST_TMUX_SOCKET=""
BUNDLE_REL="App/build/AgentWorkflowTerminal.app"

# 前面でないウィンドウへの最初のクリックは**ウィンドウのアクティブ化に消費され、
# SwiftUI の `onTapGesture` に届かない**。一方で Button は同じ状況でも反応するので、
# 「ボタンは動くのに行は動かない」を製品の欠陥と誤読しやすい (Issue #230 はこの誤読で
# 起票され not a bug として閉じた)。クリックの直前に必ずここを通す。
app_activate() {
  osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to set frontmost to true" >/dev/null
  sleep 1
  local front
  front=$(osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to return value of attribute \"AXFrontmost\"" 2>/dev/null || echo false)
  [ "$front" = "true" ] || die "アプリを前面にできませんでした。ユーザーが別のウィンドウを操作している可能性があります"
}

app_texts() {
  swift "$SCRIPT_DIR/ui-ax.swift" "$APP_NAME" list
}

app_find() {
  swift "$SCRIPT_DIR/ui-ax.swift" "$APP_NAME" find "$@"
}

app_click_text() {
  local geom
  geom=$(app_find "$@") || return 1
  app_click "$(echo "$geom" | awk '{print $1 + int($3 / 2)}')" "$(echo "$geom" | awk '{print $2 + int($4 / 2)}')"
}

app_right_click_text() {
  local geom
  geom=$(app_find "$@") || return 1
  app_click "$(echo "$geom" | awk '{print $1 + int($3 / 2)}')" "$(echo "$geom" | awk '{print $2 + int($4 / 2)}')" --right
}

# 3つ目の引数 --right で右クリックにする。宛先の pid の確認は左右で同じ。
app_click() {
  app_activate
  swift "$SCRIPT_DIR/ui-click.swift" "$1" "$2" ${3:+"$3"} || return 1
  sleep 1
}

# 非 ASCII は送れない。System Events の keystroke が別の文字へ潰す (実測: 日本語を渡すと
# `a` の連続になった)。判定に使うマーカーは ASCII で置くこと。
#
# 打鍵の宛先はこのハーネスでは決めない。**今フォーカスを持っている所へ入る**のが観測
# したい事実そのもので、宛先を指定できる API を使うとその事実を迂回してしまう。
#
# 改行はコードで拒む。Diff コメント欄が意図に反して Agent の pane へ繋がっていた場合、
# 改行はそこでコメント本文を**実行**する (§9.2.1 は貼り付けであって実行ではないと定める)。
# 人の注意力ではなくここで止める。
app_type() {
  local text="$1"
  case "$text" in
    *$'\n'*) die "type に改行は渡せません。フォーカスが端末側にあった場合、改行はコメント本文をその場で実行してしまいます" ;;
  esac
  app_activate
  # AppleScript のリテラルへ入れるので \ と " だけ潰す。
  local escaped
  escaped=$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  osascript >/dev/null <<EOS
tell application "System Events" to tell process "${APP_NAME}"
  set frontmost to true
  keystroke "${escaped}"
end tell
EOS
  sleep 1
}

# `entire contents` を舐めない。`AXFocusedUIElement` はアプリが持つ「今の宛先」そのもので、
# 階層を探索せずに取得できる。
#
# **フォーカスがどこにも無いことは失敗ではなく観測結果**として出す。#278 の確定部分は
# 「打鍵がどこにも入らない」なので、これを表せないと修正前の対照が取れない。
app_focused() {
  osascript <<EOS
tell application "System Events" to tell process "${APP_NAME}"
  try
    set fe to value of attribute "AXFocusedUIElement"
  on error
    return "NONE"
  end try
  if fe is missing value then return "NONE"
  set r to "?"
  set d to "?"
  set v to "?"
  try
    set r to (value of attribute "AXRole" of fe) as string
  end try
  try
    set d to (value of attribute "AXRoleDescription" of fe) as string
  end try
  try
    set v to (value of attribute "AXValue" of fe) as string
  end try
  return "role=" & r & " description=" & d & " value=[" & v & "]"
end tell
EOS
}

# 他の要素に同じ文字があっても打鍵の成功と誤認しないよう、フォーカス中の値だけを見る。
app_value() {
  local needle="$1" focused
  focused=$(app_focused)
  [ "$focused" != "NONE" ] || die "フォーカスを持つ要素がありません。打鍵はどこにも入っていません: ${needle}"
  case "$focused" in
    *"$needle"*) info "PASS: フォーカス中の要素に含まれます — $focused" ;;
    *) die "フォーカス中の要素に含まれません: ${needle} — $focused" ;;
  esac
}

app_quit() {
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
}

# 権限の拒否 (-25211) は待っても直らず、アプリは起動しているので「ウィンドウが開かない」と
# 区別する。$(...) の中の die は subshell しか終わらせないので、結果はグローバルで返す。
read_app_window_count() {
  local output
  if output=$(osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to return count of windows" 2>&1); then
    APP_WINDOW_COUNT=$output
    return
  fi
  case "$output" in
    *-25211*)
      die "Accessibility の権限が拒否されました (-25211)。アプリは起動していますが、ウィンドウは確かめられていません。許可先は tmux server を起動したアプリです (CLAUDE.md)"
      ;;
  esac
  APP_WINDOW_COUNT=0
}

app_launch() {
  local project="${1:-$PWD}"
  pgrep -x "$APP_NAME" >/dev/null && die "既に ${APP_NAME} が動いています。ユーザーか別の作業のインスタンスかもしれないので、操作せず確認してください"
  [ -d "$BUNDLE_REL" ] || die "バンドルがありません。先に scripts/verify-app-ui.sh build を実行してください"
  # -n が要る。`open -a <パス>` は同じ bundle id で登録済みの**別のコピー**へ渡され得るため
  # (実測: worktree のバンドルを指したのにメイン作業ツリーのバンドルが前に出た)。
  # 測っているバンドルが自分のビルドであることは、ここで担保する。
  local lane
  lane=$(basename -- "$PWD")
  local application_support="${AWT_UI_APPLICATION_SUPPORT_DIR:-/private/tmp/awt-ui-verify/${lane}/application-support}"
  local tmux_socket_name="${AWT_UI_TMUX_SOCKET_NAME:-awt-ui-verify}"
  mkdir -p "$application_support"
  # UserDefaults は bundle id の domain に入り、Application Support と違って環境変数で
  # 逸らせない。写しの bundle id を変えて、開発版と別のレーンの設定に書かないようにする (#598)。
  local bundle_id
  bundle_id="dev.local.agentworkflowterminal.ui-verify.$(printf '%s' "$lane" | LC_ALL=C tr -c 'A-Za-z0-9.-' '-')"
  local bundle_copy="/private/tmp/awt-ui-verify/${lane}/AgentWorkflowTerminal.app"
  mkdir -p "$(dirname -- "$bundle_copy")"
  rm -rf -- "$bundle_copy"
  cp -R "$PWD/$BUNDLE_REL" "$bundle_copy"
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$bundle_copy/Contents/Info.plist"
  codesign --force --sign - "$bundle_copy" >/dev/null 2>&1 || die "写したバンドルの署名に失敗しました: $bundle_copy"
  info "Application Support: $application_support"
  info "UserDefaults: defaults read $bundle_id で観測できます"
  info "tmux server: env -u TMUX tmux -L $tmux_socket_name list-sessions で観測できます"
  open -n -a "$bundle_copy" --env AWT_APPLICATION_SUPPORT_DIR="$application_support" \
    --env AWT_TMUX_SOCKET_NAME="$tmux_socket_name" --args --project "$project"
  # プロセスの存在ではなくウィンドウの数で待つ。`count of windows` はプロセスさえあれば
  # 0 を返して成功するので、成否だけを見ると窓が無いまま先へ進む。
  local i
  for i in $(seq 1 30); do
    sleep 1
    read_app_window_count
    [ "$APP_WINDOW_COUNT" -ge 1 ] && break
    [ "$i" -lt 30 ] || die "アプリのウィンドウが開きませんでした"
  done
  osascript >/dev/null <<EOS
tell application "System Events" to tell process "${APP_NAME}"
  set frontmost to true
  set w to window 1
  set position of w to {0, 25}
  set size of w to {1780, 1130}
end tell
EOS
  # ウィンドウが出た直後は Overview の行とメニューがクリックを取りこぼす。
  sleep 3
}

# socket 上で session_path が使い捨ての Project と一致する session を名前と改行で出す。
# server が居ない場合と socket ファイルが無い場合は「消すものが無い」として成功にし、それ以外の失敗は 1 を返す。
# socket ファイルの不在をそう読めるのは、open がスクリプトの TMUX_TMPDIR をアプリへ渡し、両者が
# 同じ socket ディレクトリを見るから (#861 の実測)。launchctl setenv TMUX_TMPDIR だけで設定した環境では崩れうる。
# 生きている server の socket ファイルだけが消えても同じ ENOENT になり区別できない (#492) が、
# selftest の1回の実行中にそれを起こすものは知られていないので受け入れる。
# 前置きでなく errno の文言で一致させるのは、File name too long も同じ前置きで始まり、1 に残すため。
selftest_project_sessions() {
  local socket="$1" project="$2" output name path
  if ! output=$(env -u TMUX tmux -L "$socket" list-sessions -F "#{session_name}"$'\t'"#{session_path}" 2>&1); then
    case "$output" in
      *"no server running"*) return 0 ;;
      "error connecting to "*" (No such file or directory)") return 0 ;;
    esac
    info "tmux -L ${socket} の list-sessions に失敗しました: $output"
    return 1
  fi
  while IFS=$'\t' read -r name path; do
    [ "$path" = "$project" ] && printf '%s\n' "$name"
  done <<<"$output"
  return 0
}

# trap の中から `|| …` の形で呼ぶので set -e は効かない。失敗は戻り値で返す。
# kill-server は使わない。同じ socket に別の作業の session があり得るため、自分の Project の
# session だけを `=` の完全一致で消す。
selftest_kill_project_sessions() {
  local socket="${SELFTEST_TMUX_SOCKET:-}" project="${SELFTEST_PROJECT:-}" sessions remaining name
  [ -n "$socket" ] && [ -n "$project" ] || return 0
  sessions=$(selftest_project_sessions "$socket" "$project") || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    env -u TMUX tmux -L "$socket" kill-session -t "=${name}" || info "session を消せませんでした: ${name}"
  done <<<"$sessions"
  remaining=$(selftest_project_sessions "$socket" "$project") || return 1
  [ -z "$remaining" ] && return 0
  info "使い捨ての Project の session が socket ${socket} に残っています:"
  info "$remaining"
  return 1
}

selftest_remove_scratch() {
  local scratch="${SELFTEST_SCRATCH:-}"
  case "$scratch" in
    "") return 0 ;;
    /private/tmp/awt-ui-verify/?*) rm -rf -- "$scratch" ;;
    *)
      info "想定外の場所なので消しません: ${scratch}"
      return 1
      ;;
  esac
}

# ハーネス自身が壊れていないことを確かめる最小の導線。Diff を開いて行を1つ選ぶ。
#
# Project は実行ごとに作る独立したリポジトリにする。理由は2つある。
# - socket は全 worktree で共通なので、前の実行が残した Project Root の session があると行の文言が
#   変わる (#811: `-3` だけが残っていて「表示中 shell 3」になり、「shell 1」が見つからなかった)。
#   session 名は Project Root の `<repo>/.git` から決まるので、別のパスのリポジトリなら名前が重ならない。
#   linked worktree を渡しても Project Root はメイン側になる (#231) ので、worktree では足りない。
# - 検証用の差分を作るプローブを、メイン作業ツリーに書かずに済む。
selftest() {
  local lane scratch canonical
  lane=$(basename -- "$PWD")
  SELFTEST_TMUX_SOCKET="${AWT_UI_TMUX_SOCKET_NAME:-awt-ui-verify}"
  # bash 3.2 は EXIT の trap があると、set -u の未定義の変数の参照で止まっても exit 0 を返す。
  # 最後まで走った印が無ければ非 0 で終わらせる (docs/coding-guidelines.md §7)。
  __awt_finished=0
  __awt_on_exit() {
    local rc=$?
    app_quit
    selftest_kill_project_sessions || { [ "$rc" -ne 0 ] || rc=1; }
    selftest_remove_scratch || { [ "$rc" -ne 0 ] || rc=1; }
    [[ $__awt_finished -eq 1 || $rc -ne 0 ]] || rc=1
    exit "$rc"
  }
  trap __awt_on_exit EXIT
  mkdir -p "/private/tmp/awt-ui-verify/${lane}"
  scratch=$(mktemp -d "/private/tmp/awt-ui-verify/${lane}/selftest.XXXXXX")
  # trap から見えるようにグローバルへ置く。正規化に失敗しても作った場所は消せるよう、先に生の値を置く。
  SELFTEST_SCRATCH="$scratch"
  canonical=$(cd -- "$scratch" && pwd -P)
  SELFTEST_SCRATCH="$canonical"
  SELFTEST_PROJECT="$SELFTEST_SCRATCH/project"
  mkdir -- "$SELFTEST_PROJECT"
  git -C "$SELFTEST_PROJECT" init -q
  printf 'verify-app-ui selftest\n' >"$SELFTEST_PROJECT/README"
  git -C "$SELFTEST_PROJECT" add README
  # 利用者の git 設定 (署名・hook・未設定の user) で commit が止まらないようにする。
  git -C "$SELFTEST_PROJECT" -c user.name=awt-ui-selftest -c user.email=awt-ui-selftest@invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "selftest"
  # 分岐元も origin/HEAD も無いと Diff の base が決まらず、プローブの差分が出ない
  # (#811 の実測: `base: 未決定`)。base は origin/HEAD で決めさせる。remote は要らず ref だけで足りる。
  git -C "$SELFTEST_PROJECT" update-ref refs/remotes/origin/main HEAD
  git -C "$SELFTEST_PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'probe line one\nprobe line two\nprobe line three\n' >"$SELFTEST_PROJECT/verify-app-ui-probe.txt"
  # 利用者の値より優先する。lane の Application Support だと前回までに登録した Project を引き継ぐ。
  AWT_UI_APPLICATION_SUPPORT_DIR="$SELFTEST_SCRATCH/application-support"
  app_launch "$SELFTEST_PROJECT"
  # Overview の Agent がいない行は「shell 1」、表示中は「表示中 shell 1」なので部分一致で選ぶ。
  # ボタンの順番に依存しないよう、文言と role で対象を特定する。
  app_click_text "shell 1" --role AXButton
  app_click_text "Viewer" --exact --role AXMenuButton
  swift "$SCRIPT_DIR/ui-ax.swift" "$APP_NAME" press "Diff" --exact --role AXMenuItem
  sleep 2
  # Diff は開いた時点で自動で表示される (#830)。
  sleep 4
  local geom x y
  geom=$(app_find "probe line two")
  x=$(echo "$geom" | awk '{print $1 + int($3 / 2)}')
  y=$(echo "$geom" | awk '{print $2 + int($4 / 2)}')
  info "行 'probe line two' を ($x, $y) でクリックします"
  app_click "$x" "$y"
  # クリック直後の1回の探索では、AX への反映が間に合わないことがある (#430 の実測: Diff を上下に
  # 並べたとき、直後の find は外れ、続けて取った texts には「選択中」が出ていた)。期限付きで待つ。
  local tries=0
  until app_find "選択中" >/dev/null 2>&1 || [ "$tries" -ge 10 ]; do
    sleep 0.5
    tries=$((tries + 1))
  done
  if app_find "選択中" >/dev/null; then
    info "PASS: 行選択が効いています"
  else
    info "実際の表示: $(app_texts)"
    die "FAIL: 行を選択できませんでした"
  fi
  selftest_typing
  __awt_finished=1
}

# type / focused / value がハーネスとして機能することだけを確かめる。**製品側の
# フォーカス調停 (#278) には依存させない** — エディタを明示的にクリックしてから打つ。
# 依存させると、次に打鍵が入らなかったときハーネスと製品のどちらが壊れたのか切り分けられず、
# #230 と同じ誤読に戻る。
selftest_typing() {
  # 座標を決め打ちしない。コメント欄は「選択中:」ラベルの直下にあるので、その位置から出す。
  local geom x y
  geom=$(app_find "選択中")
  x=$(echo "$geom" | awk '{print $1 + int($3 / 2)}')
  y=$(echo "$geom" | awk '{print $2 + $4 + 40}')
  info "コメント欄を ($x, $y) でクリックします"
  app_click "$x" "$y"
  app_type "EDITORTEST"
  info "focused: $(app_focused)"
  app_value "EDITORTEST"
}

[ $# -ge 1 ] || {
  usage
  exit 1
}

command=$1
shift

repo_root_cd
require_cmd osascript swift open pkill git

case "$command" in
  -h | --help) usage ;;
  build) "$SCRIPT_DIR/build-app.sh" ;;
  launch)
    if [ "${1:-}" = "--project" ]; then
      require_value "--project" $#
      app_launch "$2"
    else
      app_launch "$PWD"
    fi
    ;;
  activate) app_activate ;;
  texts) app_texts ;;
  find)
    [ $# -ge 1 ] || die "find には検索する文字列が必要です"
    app_find "$@"
    ;;
  click)
    [ $# -ge 2 ] || die "click には x と y が必要です"
    app_click "$1" "$2"
    ;;
  click-text)
    [ $# -ge 1 ] || die "click-text には検索する文字列が必要です"
    app_click_text "$@"
    ;;
  right-click)
    [ $# -ge 2 ] || die "right-click には x と y が必要です"
    app_click "$1" "$2" --right
    ;;
  right-click-text)
    [ $# -ge 1 ] || die "right-click-text には検索する文字列が必要です"
    app_right_click_text "$@"
    ;;
  expect)
    [ $# -ge 1 ] || die "expect には検索する文字列が必要です"
    app_find "$@" >/dev/null
    ;;
  type)
    [ $# -ge 1 ] || die "type には打鍵する文字列が必要です"
    app_type "$1"
    ;;
  focused) app_focused ;;
  value)
    [ $# -ge 1 ] || die "value には検索する文字列が必要です"
    app_value "$1"
    ;;
  quit) app_quit ;;
  selftest)
    require_cmd tmux
    [ "${1:-}" = "--no-build" ] || "$SCRIPT_DIR/build-app.sh" >/dev/null
    selftest
    ;;
  *) die "不明なサブコマンド: $command" ;;
esac
