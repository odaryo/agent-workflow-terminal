#!/bin/bash
# Gate 1 M3 — DECSTBM スクロールリージョン。
# 3〜10 行目だけがスクロールし、TOP / BOTTOM の固定行が動かないことを確認する。
clear
printf '\033[1;1HTOP FIXED LINE (must not move) ================'
printf '\033[12;1HBOTTOM FIXED LINE (must not move) ============='
printf '\033[3;10r'
for i in $(seq 1 25); do
  printf '\033[10;1H\n  scroll-region line %02d\n' $i
  perl -e 'select(undef,undef,undef,0.02)'
done
printf '\033[r'
printf '\033[14;1Hscroll region test done\n'
