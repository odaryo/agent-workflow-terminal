#!/usr/bin/env bash
# iPad の端末で表示幅と色を目で確かめるための出力。各行末の | が縦にそろえば幅は正しい。
set -euo pipefail

printf 'TERM=%s COLORTERM=%s cols=%s rows=%s\n' "${TERM:-}" "${COLORTERM:-}" "$(tput cols)" "$(tput lines)"
echo
echo '== 表示幅 (各行の | がそろうこと) =='
printf '%s|\n' \
  'abcdefghij' \
  'あいうえお' \
  'ｱｲｳｴｵｶｷｸｹｺ' \
  '漢字テスト' \
  '😀😃😄😁😆' \
  '👍🏽👍🏽👍🏽👍🏽👍🏽' \
  '🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵' \
  '👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧👨‍👩‍👧' \
  '❤️❤️❤️❤️❤️'
echo
echo '== 罫線 =='
echo '┌──┬──┐'
echo '│あ│ab│'
echo '└──┴──┘'
echo
echo '== true color (なめらかなグラデーションなら OK) =='
for row in 0 1 2; do
  for i in $(seq 0 2 159); do
    r=$(( row == 0 ? i * 255 / 159 : 0 ))
    g=$(( row == 1 ? i * 255 / 159 : 0 ))
    b=$(( row == 2 ? i * 255 / 159 : 0 ))
    printf '\033[48;2;%d;%d;%dm \033[0m' "$r" "$g" "$b"
  done
  echo
done
echo
echo '== 256 色 =='
for i in $(seq 16 51); do printf '\033[48;5;%dm  \033[0m' "$i"; done
echo
echo '== 装飾 =='
printf '\033[1m太字\033[0m \033[3m斜体\033[0m \033[4m下線\033[0m \033[7m反転\033[0m \033[9m取消線\033[0m\n'
