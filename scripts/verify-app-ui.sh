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
  texts                 メインペインの静的テキストをすべて出す (状態の読み取り用)
  find <部分文字列>      その文字列を含む静的テキストの "x y w h" を出す
  click <x> <y>         activate してから実 HID クリックを送る
  click-text <部分文字列> find した要素の中心を click する
  expect <部分文字列>    メインペインのどこかにその文字列があれば成功、無ければ失敗
  type <文字列>          今フォーカスがある所へ打鍵する (改行は拒否する)
  focused               フォーカスを持つ要素の role / description / value を出す
  value <部分文字列>     フォーカス中の要素の値にその文字列があれば成功、無ければ失敗
  quit                  起動したアプリを終了する
  selftest [--no-build] 行選択が効くところまでを1コマンドで通す (ハーネス自身の動作確認)
  -h, --help            このヘルプを表示

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
  osascript <<EOS
tell application "System Events" to tell process "${APP_NAME}"
  set out to ""
  repeat with e in static texts of group 1 of window 1
    set out to out & "[" & (value of e as string) & "]"
  end repeat
  return out
end tell
EOS
}

# 座標を決め打ちしない。Accessibility が返す要素の位置と大きさから中心を出す。
#
# `entire contents` では Diff の行に届かない。SwiftUI の LazyVStack がぶら下がる
# scroll area の中身は再帰列挙に現れないため (実測: entire contents は 51 要素しか返さず
# 行のテキストを含まなかった)、scroll area の直下も明示的に舐める。
app_find() {
  local needle="$1" geom
  geom=$(osascript <<EOS
tell application "System Events" to tell process "${APP_NAME}"
  set g to group 1 of window 1
  set out to "NONE"
  repeat with e in static texts of g
    try
      if (value of e as string) contains "${needle}" then
        set p to position of e
        set s to size of e
        set out to ((item 1 of p) as string) & " " & ((item 2 of p) as string) & " " & ((item 1 of s) as string) & " " & ((item 2 of s) as string)
      end if
    end try
  end repeat
  if out is "NONE" then
    repeat with sa in scroll areas of g
      repeat with ue in UI elements of sa
        try
          repeat with e in static texts of ue
            if (value of e as string) contains "${needle}" then
              set p to position of e
              set s to size of e
              set out to ((item 1 of p) as string) & " " & ((item 2 of p) as string) & " " & ((item 1 of s) as string) & " " & ((item 2 of s) as string)
              exit repeat
            end if
          end repeat
        end try
      end repeat
    end repeat
  end if
  return out
end tell
EOS
)
  [ "$geom" != "NONE" ] || die "要素が見つかりません: ${needle}"
  echo "$geom"
}

app_click() {
  app_activate
  swift "$SCRIPT_DIR/ui-click.swift" "$1" "$2"
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
# app_find が届かない階層 (LazyVStack の中など) にあっても1発で取れる。
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

# `expect` のテキスト入力版。`app_texts` は static text しか見ないので、TextEditor に
# 入った文字はそちらでは読めない。
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
  osascript >/dev/null <<EOS
tell application "System Events" to tell process "${APP_NAME}"
  set frontmost to true
  set w to window 1
  click button 1 of scroll area 1 of group 1 of w
  delay 1
  click menu button "Viewer" of group 1 of w
  delay 1
  click (first UI element of (UI element 1 of menu button "Viewer" of group 1 of w) whose title is "Diff")
  delay 2
  click button 3 of group 1 of w
end tell
EOS
  sleep 4
  local geom x y
  geom=$(app_find "probe line two")
  x=$(echo "$geom" | awk '{print $1 + int($3 / 2)}')
  y=$(echo "$geom" | awk '{print $2 + int($4 / 2)}')
  info "行 'probe line two' を ($x, $y) でクリックします"
  app_click "$x" "$y"
  if app_texts | grep -q "選択中"; then
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
    app_find "$1"
    ;;
  click)
    [ $# -ge 2 ] || die "click には x と y が必要です"
    app_click "$1" "$2"
    ;;
  click-text)
    [ $# -ge 1 ] || die "click-text には検索する文字列が必要です"
    geom=$(app_find "$1")
    app_click "$(echo "$geom" | awk '{print $1 + int($3 / 2)}')" "$(echo "$geom" | awk '{print $2 + int($4 / 2)}')"
    ;;
  expect)
    [ $# -ge 1 ] || die "expect には検索する文字列が必要です"
    app_texts | grep -q -- "$1" || die "見つかりませんでした: $1"
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
