#!/bin/bash
# Gate 1 M3 — grapheme width の**数値**確認。
# 文字列を出力した直後のカーソル桁を DSR(CPR, ESC[6n) で問い合わせ、期待幅と比べる。
# tmux 経由 (m3-harness.sh launch) と tmux 無し (launch-bare) の両方で走らせて
# 「tmux が壊しているのか libghostty が壊しているのか」を切り分ける。
probe() {
  local label="$1" s="$2" expect="$3"
  printf '\r\033[K%s' "$s"
  printf '\033[6n'
  IFS= read -r -d 'R' -s -t 2 resp </dev/tty
  local col="${resp##*;}"
  local actual=$(( col - 1 ))
  printf '\r\033[K%-14s expect=%-3s actual=%-3s %s  [%s]\n' \
     "$label" "$expect" "$actual" "$( [ "$actual" = "$expect" ] && echo OK || echo DIFF )" "$s"
}
probe ascii        'abcdef'        6
probe hiragana     'あいう'        6
probe kanji        '漢字混在'      8
probe fullwidth    'ＡＢＣ'        6
probe ambiguous    '±○△×'        4
probe emoji1       '😀🍣'          4
probe zwj-family   '👨‍👩‍👧‍👦'          2
probe zwj-tech     '👩‍💻'            2
probe skin         '👍🏽'            2
probe flag-jp      '🇯🇵'            2
probe vs16         '❤️'             2
probe vs15         '❤︎'             1
probe combining    'é'             1
probe hangul       '한국어'        6
