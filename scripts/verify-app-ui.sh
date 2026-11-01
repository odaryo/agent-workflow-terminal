#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck disable=SC1091 # 実行時に解決するパスのため静的解析では追跡できない
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
使い方: scripts/verify-app-ui.sh <サブコマンド> [引数...]

App/ の UI 配線を実機で確認するためのハーネス。CLAUDE.md「Agent workflow」の
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
  expect <文字列> [--exact] [--role AXRole]
                        find で見つかれば成功、無ければ失敗 (ボタン・タブ・sheet も対象)
  type <文字列>          今フォーカスがある所へ打鍵する (改行は拒否する)
  focused               フォーカスを持つ要素の role / description / value を出す
  value <部分文字列>     フォーカス中の要素の値にその文字列があれば成功、無ければ失敗
  quit                  起動したアプリを終了する
  selftest [--no-build] 行選択が効くところまでを1コマンドで通す (ハーネス自身の動作確認)
  -h, --help            このヘルプを表示

検索対象: AXTitle / AXValue / AXDescription / AXAttributedDescription。
texts の各文言は引用符付きで、改行などはエスケープして出す。

**必ず最終バンドル (scripts/build-app.sh の出力) を対象にすること。** probe ビルドで
確認した結果を完了報告に使わない。
EOF
}

APP_NAME="AgentWorkflowTerminalApp"
SELFTEST_PROBE=""
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

app_click() {
  app_activate
  swift "$SCRIPT_DIR/ui-click.swift" "$1" "$2" || return 1
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

app_launch() {
  local project="${1:-$PWD}"
  pgrep -x "$APP_NAME" >/dev/null && die "既に ${APP_NAME} が動いています。ユーザーか別の作業のインスタンスかもしれないので、操作せず確認してください"
  [ -d "$BUNDLE_REL" ] || die "バンドルがありません。先に scripts/verify-app-ui.sh build を実行してください"
  # -n が要る。`open -a <パス>` は同じ bundle id で登録済みの**別のコピー**へ渡され得るため
  # (実測: worktree のバンドルを指したのにメイン作業ツリーのバンドルが前に出た)。
  # 測っているバンドルが自分のビルドであることは、ここで担保する。
  open -n -a "$PWD/$BUNDLE_REL" --args --project "$project"
  # プロセスの存在ではなくウィンドウの数で待つ。`count of windows` はプロセスさえあれば
  # 0 を返して成功するので、成否だけを見ると窓が無いまま先へ進む。
  local i windows
  for i in $(seq 1 30); do
    sleep 1
    windows=$(osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to return count of windows" 2>/dev/null || echo 0)
    [ "$windows" -ge 1 ] && break
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
  # ウィンドウが出た直後はタブとメニューがクリックを取りこぼす (実測)。
  sleep 3
}

# ハーネス自身が壊れていないことを確かめる最小の導線。Diff を開いて行を1つ選ぶ。
# 検証用の差分を作るため、リポジトリに untracked のプローブファイルを一時的に置く。
selftest() {
  # Project Root タブが指すのは常にリポジトリのメイン作業ツリーで、worktree はタスクタブ側に並ぶ
  # (実測: worktree のパスを --project に渡しても Project Root はメイン側になる)。タブの選択を
  # index に頼らず済ませるため、プローブはメイン作業ツリーへ置いて Project Root タブで見る。
  local main_worktree
  main_worktree=$(git worktree list --porcelain | awk 'NR == 1 { print $2 }')
  [ -n "$main_worktree" ] || die "メイン作業ツリーを特定できませんでした"
  # trap から見えるようにグローバルへ置く。local だと関数を抜けた時点で参照できない。
  SELFTEST_PROBE="$main_worktree/verify-app-ui-probe.txt"
  trap 'rm -f "${SELFTEST_PROBE:-}"; app_quit' EXIT
  printf 'probe line one\nprobe line two\nprobe line three\n' >"$SELFTEST_PROBE"
  app_launch "$main_worktree"
  # ボタンの順番は UI の変更でずれたため、文言と role で対象を特定する (#414)。
  app_click_text "Project Root" --exact --role AXButton
  app_click_text "Viewer" --exact --role AXMenuButton
  swift "$SCRIPT_DIR/ui-ax.swift" "$APP_NAME" press "Diff" --exact --role AXMenuItem
  sleep 2
  app_click_text "開く" --exact --role AXButton
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
require_cmd osascript swift open pkill

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
    [ "${1:-}" = "--no-build" ] || "$SCRIPT_DIR/build-app.sh" >/dev/null
    selftest
    ;;
  *) die "不明なサブコマンド: $command" ;;
esac
