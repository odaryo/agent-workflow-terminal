#!/usr/bin/env python3
"""scripts/stop-tty-processes.sh の宛先の判定。ps の 2 つの断面を比べるだけで、何も止めない。

入力は `LC_ALL=C ps -A -o pid=,pgid=,tty=,lstart=,args=` の出力を 2 つ — 記録したときの断面
(--recorded) と今の断面 (--now)。記録は、指定した tty の上のプロセス (--self を除く) に限る。
出力は 1 行 1 件で、次の順に並ぶ (開始時刻は lstart の 5 語を `_` でつないだもの)。

  recorded <pid> <pgid> <tty> <開始時刻> <args>   記録したプロセス
  target -<pgid> | target <pid>                    KILL (と TERM) の宛先
  alive <pid> <記録した pgid> <今の pgid>          記録したもので、今も生きているもの
  group <pid> <pgid> <tty> <開始時刻> <args>       記録した pgid にいる、記録に無いプロセス
  tty <pid> <pgid> <tty> <開始時刻> <args>         指定した tty の上にいる、記録に無いプロセス

「生きている」は、同じ pid で開始時刻も同じものに限る。pid が再利用されて別のプロセスに
なっていても撃たないため。生きているものが記録した pgid にまだいれば宛先は `-<pgid>`、別の
group へ移っていればその pid だけを宛先にする (元の pgid は、group が空になれば別の group に
再利用されうる)。

group と tty には宛先を出さない。group は TERM の後に fork した子 (Issue #573 の m5) でありうるが、
記録したものが消えて group が空になった後に、同じ番号が別の group に再利用された可能性を
除外できない。tty は、止めている途中に pane が閉じ、別の server の新しい pane が同じ tty を
受け取った可能性がある (#540)。両方に当たるものは group にだけ出す。

次のどれかに当たるときは、何も出さずに exit 2 で終わる。

  - ps の行の形が想定と違う
  - 断面が改行で終わっていない (行の途中で切れている)
  - --self の行がどちらかの断面に無い (空の断面を含む)

確かめるのはこの 3 つだけで、断面が最後まであることは確かめない。行の境目で切れた断面は、
--self の行がその前にあれば通り、記録したものが「消えた」と読まれうる。ps が途中で失敗した
場合は、stop-tty-processes.sh が ps の終了コードで止める。

依存は標準ライブラリのみ。macOS の /usr/bin/python3 (3.9) でも動く書き方にする。
"""

import argparse
import re
import sys

# lstart は LC_ALL=C で `Mon Nov  2 22:47:27 2026` の形 (日が 1 桁だと空白が 2 つ)。
# args の改行は ps が `\012` に置き換えるので、1 行が 1 プロセスになる (実測 macOS 27)。
_ROW_RE = re.compile(
    r"^\s*([0-9]{1,10})\s+([0-9]{1,10})\s+(\S+)\s+"
    r"([A-Z][a-z]{2})\s+([A-Z][a-z]{2})\s+([0-9]{1,2})\s+([0-9]{2}:[0-9]{2}:[0-9]{2})\s+([0-9]{4})"
    r"(?:\s+(.*))?$"
)


class InputError(Exception):
    pass


class Row:
    __slots__ = ("pid", "pgid", "tty", "start", "args")

    def __init__(self, pid, pgid, tty, start, args):
        self.pid = pid
        self.pgid = pgid
        self.tty = tty
        self.start = start
        self.args = args

    def key(self):
        return (self.pid, self.start)

    def describe(self):
        text = "%d %d %s %s" % (self.pid, self.pgid, self.tty, self.start)
        return text + " " + self.args if self.args else text


def parse_ps(text, label):
    if text and not text.endswith("\n"):
        raise InputError("%s の断面が改行で終わっていません (行の途中で切れています)" % label)
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        match = _ROW_RE.match(line)
        if match is None:
            raise InputError("%s の %d 行目が ps の形ではありません: %r" % (label, number, line))
        groups = match.groups()
        rows.append(
            Row(
                int(groups[0]),
                int(groups[1]),
                groups[2],
                "_".join(groups[3:8]),
                (groups[8] or "").strip(),
            )
        )
    return rows


def plan(recorded_snapshot, now_snapshot, ttys, self_pid):
    for label, rows in (("--recorded", recorded_snapshot), ("--now", now_snapshot)):
        if not any(row.pid == self_pid for row in rows):
            raise InputError("%s の断面に --self (%d) の行がありません" % (label, self_pid))

    wanted = set(ttys)
    recorded = [row for row in recorded_snapshot if row.tty in wanted and row.pid != self_pid]
    recorded_keys = set(row.key() for row in recorded)
    recorded_pgids = set(row.pgid for row in recorded)
    now_by_pid = {}
    for row in now_snapshot:
        now_by_pid[row.pid] = row

    targets = []
    alive = []
    for row in recorded:
        now = now_by_pid.get(row.pid)
        if now is None or now.start != row.start:
            continue
        alive.append((row.pid, row.pgid, now.pgid))
        target = "-%d" % row.pgid if now.pgid == row.pgid else "%d" % row.pid
        if target not in targets:
            targets.append(target)

    group = []
    on_tty = []
    for row in now_snapshot:
        if row.pid == self_pid or row.key() in recorded_keys:
            continue
        if row.pgid in recorded_pgids:
            group.append(row)
        elif row.tty in wanted:
            on_tty.append(row)

    lines = ["recorded " + row.describe() for row in recorded]
    lines += ["target " + target for target in targets]
    lines += ["alive %d %d %d" % entry for entry in alive]
    lines += ["group " + row.describe() for row in group]
    lines += ["tty " + row.describe() for row in on_tty]
    return lines


def read_text(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as handle:
        return handle.read()


def main(argv):
    parser = argparse.ArgumentParser(description="stop-tty-processes.sh の宛先の判定")
    parser.add_argument("--self", dest="self_pid", type=int, required=True)
    parser.add_argument("--recorded", required=True)
    parser.add_argument("--now", required=True)
    parser.add_argument("ttys", nargs="+")
    args = parser.parse_args(argv)
    try:
        lines = plan(
            parse_ps(read_text(args.recorded), "--recorded"),
            parse_ps(read_text(args.now), "--now"),
            args.ttys,
            args.self_pid,
        )
    except (InputError, OSError) as error:
        sys.stderr.write("stop_tty_targets.py: %s\n" % error)
        return 2
    # args は UTF-8 とは限らないので、読んだバイト列のまま返す。
    sys.stdout.buffer.write("".join(line + "\n" for line in lines).encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
