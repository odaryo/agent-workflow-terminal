#!/usr/bin/env bash
# Gate 3 スパイク共通設定。使い捨てコード (docs/coding-guidelines.md §6 により CI 対象外)。
set -euo pipefail

# ユーザーの実 tmux server を汚さないための隔離 socket (PLAN.md M0)。
export G3_SOCKET="${G3_SOCKET:-gate3-spike}"
G3_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export G3_ROOT
export G3_EVIDENCE="${G3_EVIDENCE:-$G3_ROOT/evidence}"
# Agent に触らせる作業ディレクトリ。本リポジトリを対象にしない (PLAN.md M0 / §8 R6)。
export G3_WORK="${G3_WORK:-${TMPDIR:-/tmp}/gate3-work}"

g3_tmux() { tmux -L "$G3_SOCKET" "$@"; }

g3_now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000'; }

g3_reset_work() {
  rm -rf "$G3_WORK"
  mkdir -p "$G3_WORK"
  printf 'hello\n' >"$G3_WORK/README.md"
  git -C "$G3_WORK" init -q
  git -C "$G3_WORK" add -A
  git -C "$G3_WORK" -c user.email=spike@example.invalid -c user.name=gate3 commit -qm init
}

g3_kill_server() { g3_tmux kill-server 2>/dev/null || true; }
