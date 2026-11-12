#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: ci-brew-preinstall.sh start <formula>...
        ci-brew-preinstall.sh wait <command>...
        ci-brew-preinstall.sh link

CI 専用 (Issue #1012)。brew install の待ちを、CLI の要らない段 (ビルド) の裏へ回す。

  start  `brew install` と直後の `brew unlink` を裏で始めてすぐ戻る。
  wait   裏の処理の終わりを待ち (上限 300 秒)、<command> が PATH に無いことを確かめる。
         単体テストを CLI の無い環境で回す段の前に呼ぶ。在れば exit 1。
  link   start に渡した formula を /opt/homebrew へリンクする。裏の導入が落ちていれば、
         ここで `brew install` し直す。

  -h, --help  このヘルプを表示
USAGE
}

state_dir="${RUNNER_TEMP:?RUNNER_TEMP がありません (CI 専用です)}/brew-preinstall"

finished() { [[ -s "$state_dir/status" ]]; }

# macOS の /bin/bash 3.2 には mapfile が無い。
read_formulae() {
  formulae=()
  while IFS= read -r formula; do formulae+=("$formula"); done <"$state_dir/formulae"
}

case "${1:-}" in
  start)
    shift
    [[ $# -gt 0 ]] || { usage >&2; exit 2; }
    mkdir -p "$state_dir"
    rm -f "$state_dir/status"
    printf '%s\n' "$@" >"$state_dir/formulae"
    # 単体テストは CLI の無い環境で回す (TmuxRunner / RipgrepRunner は PATH のほかに
    # /opt/homebrew/bin の固定パスも探す)。そのため導入した直後に unlink し、/opt/homebrew/bin に
    # 置かない。unlink までの間にテストが始まらないよう、wait がこの終わりを待つ。
    # `brew fetch` で取得だけを先にする方式は効かなかった: 取得済みでも brew install の起動と
    # 確認に約 11s、pour に約 12s かかった (run 43136338586)。
    # 裏のプロセスは段が終わっても生き、GitHub-hosted runner は job の最後に孤児を片付ける。
    # shellcheck disable=SC2016 # 展開は裏の bash で行う
    nohup bash -c 'brew install "$@" && brew unlink "$@"; echo "$?" >"$0/status"' \
      "$state_dir" "$@" >"$state_dir/log" 2>&1 &
    echo "$!" >"$state_dir/pid"
    echo "brew install $* を裏で始めた (導入後に unlink する)"
    ;;
  wait)
    shift
    [[ -d "$state_dir" ]] || { echo "::error::start が呼ばれていない"; exit 1; }
    pid=$(cat "$state_dir/pid")
    for ((i = 0; i < 600; i++)); do
      finished && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    echo "::group::裏の brew install のログ"
    cat "$state_dir/log" || true
    echo "::endgroup::"
    if ! finished; then
      # まだ動いていれば、この後のテストの最中にリンクしうる。
      kill -0 "$pid" 2>/dev/null && { echo "::error::裏の brew install が 300 秒で終わらなかった"; exit 1; }
      echo "::warning::裏の brew install が status を書かずに消えた。link の段で導入し直す"
    elif [[ "$(cat "$state_dir/status")" != 0 ]]; then
      echo "::warning::裏の brew install が exit $(cat "$state_dir/status") で終わった。link の段で導入し直す"
    fi
    # 落ちた場合も、途中までリンクされたものを外しておく。
    read_formulae
    brew unlink "${formulae[@]}" >/dev/null 2>&1 || true
    status=0
    for command in "$@"; do
      if found=$(command -v "$command"); then
        echo "::error::$command が PATH に在る ($found)。単体テストを CLI の無い環境で回せない"
        status=1
      fi
    done
    exit "$status"
    ;;
  link)
    [[ -s "$state_dir/formulae" ]] || { echo "::error::start が呼ばれていない"; exit 1; }
    read_formulae
    # 導入済みで未リンクなら link だけで済む。未導入のものがあれば link は落ちるので導入し直す
    # (導入済みで未リンクの formula に brew install は何もしないので、もう一度 link する)。
    if ! brew link "${formulae[@]}"; then
      brew install "${formulae[@]}"
      brew link "${formulae[@]}"
    fi
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
