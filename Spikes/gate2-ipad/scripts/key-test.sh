#!/usr/bin/env bash
# 押したキーが端末へ届いたバイト列を16進で1行ずつ表示する。q を単独で押すと終わる。
# raw にするので Ctrl-C も Ctrl-Z もそのまま 03 / 1a として表示される。
set -euo pipefail

saved=$(stty -g)
trap 'stty "$saved"' EXIT
stty raw -echo
printf 'キーを押してください (q で終了)\r\n'
while :; do
  # 1 バイト目を待ってから、同じキーの残り (エスケープシーケンス) を 0.05 秒だけ拾う。
  first=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$first" = "71" ] && break
  stty min 0 time 1
  rest=$(dd bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d '\n' | sed 's/^ *//')
  stty min 1 time 0
  printf '%s %s\r\n' "$first" "$rest"
done
printf '終了\r\n'
