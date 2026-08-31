#!/bin/bash
# Gate 1 M3 — 256色 / truecolor / SGR / box drawing。
# vttest が無い環境での代替。pane 内で `bash vt-color.sh` として実行する。
printf '\033[1mTERM=%s COLORTERM=%s\033[0m\n' "$TERM" "$COLORTERM"
printf 'ANSI 16: '
for i in $(seq 0 15); do printf '\033[48;5;%dm  \033[0m' $i; done; echo
printf '256 cube: '
for i in $(seq 16 123); do printf '\033[48;5;%dm \033[0m' $i; done; echo
printf '          '
for i in $(seq 124 231); do printf '\033[48;5;%dm \033[0m' $i; done; echo
printf 'grayscale: '
for i in $(seq 232 255); do printf '\033[48;5;%dm \033[0m' $i; done; echo
printf 'truecolor: '
for i in $(seq 0 71); do r=$((255-i*3)); g=$((i*7%256)); b=$((i*3)); printf '\033[48;2;%d;%d;%dm \033[0m' $r $g $b; done; echo
printf 'SGR: \033[1mbold\033[0m \033[2mdim\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m '
printf '\033[4:3mcurly\033[0m \033[58;5;196m\033[4:3mcurly-red\033[0m \033[5mblink\033[0m \033[7mreverse\033[0m \033[9mstrike\033[0m \033[21mdouble-ul\033[0m\n'
printf 'box: ┌─┬─┐ │ └─┴─┘ ╚═╩═╝ █▓▒░ ▲▼◀▶\n'
printf 'powerline-ish:    braille: ⠇⡇⣇\n'
