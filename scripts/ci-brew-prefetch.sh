#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
使い方: ci-brew-prefetch.sh start <formula>...
        ci-brew-prefetch.sh wait

CI 専用 (Issue #1012)。start は `brew fetch --deps` を裏で始めてすぐ戻る。wait は取得が
終わるまで待ち (上限 300 秒)、取得のログを出す。

取得が落ちても、時間切れでも wait は 0 で終わる。後の `brew install` が自分で取り直すので、
ここで CI を落とすと情報が増えずに遅れだけが増える。

  -h, --help  このヘルプを表示
EOF
}

state_dir="${RUNNER_TEMP:?RUNNER_TEMP がありません (CI 専用です)}/brew-prefetch"

case "${1:-}" in
  start)
    shift
    [[ $# -gt 0 ]] || { usage >&2; exit 2; }
    mkdir -p "$state_dir"
    rm -f "$state_dir/status"
    # `brew fetch` はダウンロードキャッシュに置くだけで /opt/homebrew/bin へリンクしない。
    # 単体テストを CLI の無い環境で回す前提 (TmuxRunner / RipgrepRunner は /opt/homebrew/bin の
    # 固定パスも探す) を崩さないのは、このため。
    # 裏のプロセスは段が終わっても生き、GitHub-hosted runner は job の最後に孤児を片付ける。
    # shellcheck disable=SC2016 # 展開は裏の bash で行う
    nohup bash -c 'brew fetch --deps "$@" >"$0/log" 2>&1; echo "$?" >"$0/status"' \
      "$state_dir" "$@" >/dev/null 2>&1 &
    echo "$!" >"$state_dir/pid"
    echo "brew fetch --deps $* を裏で始めた"
    ;;
  wait)
    if [[ ! -d "$state_dir" ]]; then
      echo "取得は始まっていない"
      exit 0
    fi
    # 取得が続いたまま `brew install` を始めると、同じ bottle を取り合う。裏のプロセスが
    # status を書かずに消えていたら (段の終わりで止められた場合など)、それ以上は待たない。
    pid=$(cat "$state_dir/pid" 2>/dev/null || true)
    for ((i = 0; i < 600; i++)); do
      [[ -s "$state_dir/status" ]] && break
      [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && [[ ! -s "$state_dir/status" ]] && break
      sleep 0.5
    done
    echo "::group::brew fetch のログ"
    cat "$state_dir/log" 2>/dev/null || true
    echo "::endgroup::"
    if [[ ! -s "$state_dir/status" ]]; then
      echo "::warning::brew fetch の終わりを確かめられなかった (300 秒の時間切れか、裏のプロセスが消えた)。brew install が自分で取得する"
    elif [[ "$(cat "$state_dir/status")" != 0 ]]; then
      echo "::warning::brew fetch が exit $(cat "$state_dir/status") で終わった。brew install が自分で取得する"
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
