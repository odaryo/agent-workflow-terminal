#!/usr/bin/env bash
# check-orphan-warning.sh が AWT_ORPHAN_WARNING_PS に差し込む ps の代役。
# $ORPHAN_FIXTURE_CASE の fixture を、実測で取ったときと同じ引数で呼ばれたときだけ返す。
# それ以外の引数を拒否するのは、comm の後ろに列を足すと comm が 16 文字で切れるため
# (実測: `ps -o pid=,comm=,args=` で /private/tmp/cla)。引数が変わったら fixture を取り直すこと。
set -euo pipefail

case "$*" in
  "-A -o pid=,ppid=,pgid=,%cpu=,tty=,args=") cat "$ORPHAN_FIXTURE_CASE/ps-args.txt" ;;
  "-A -o pid=,comm=") cat "$ORPHAN_FIXTURE_CASE/ps-comm.txt" ;;
  *)
    echo "fake-ps: fixture を取ったときと違う引数です: $*" >&2
    exit 64
    ;;
esac
