#!/usr/bin/env bash
# check-orphan-warning.sh が AWT_ORPHAN_WARNING_PS に差し込む ps の代役。
# $ORPHAN_FIXTURE_CASE の fixture を、実測で取ったときと同じ引数で呼ばれたときだけ返す。
# それ以外の引数を拒否するのは、comm の後ろに列を足すと comm が 16 文字で切れるため
# (実測: `ps -o pid=,comm=,args=` で /private/tmp/cla)。引数が変わったら fixture を取り直すこと。
#
# FAKE_PS_SLEEP を与えると、出力の前にその秒数だけ待つ (ps 2 回で共有する期限の検査用)。
# sleep の stdout を閉じておくのは、親が kill されても sleep が pipe を握って EOF を遅らせないため。
set -euo pipefail

if [[ -n "${FAKE_PS_SLEEP:-}" ]]; then
  sleep "$FAKE_PS_SLEEP" >/dev/null 2>&1
fi

case "$*" in
  "-A -o pid=,ppid=,pgid=,uid=,%cpu=,tty=,args=") cat "$ORPHAN_FIXTURE_CASE/ps-args.txt" ;;
  "-A -o pid=,comm=") cat "$ORPHAN_FIXTURE_CASE/ps-comm.txt" ;;
  *)
    echo "fake-ps: fixture を取ったときと違う引数です: $*" >&2
    exit 64
    ;;
esac
