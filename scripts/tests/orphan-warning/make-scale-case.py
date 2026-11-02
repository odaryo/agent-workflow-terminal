#!/usr/bin/env python3
"""check-orphan-warning.sh の規模の検査用に、候補が n 件ある fixture を作る。

使い方: make-scale-case.py <元の case ディレクトリ> <n> <出力ディレクトリ>

元の case の 1 行目 (実測の行) を、pid と pgid を 100000 から振り直して n 行に複製する。
#517 では同じ形の孤児が 120 個残った。
"""

import os
import re
import sys


def main():
    source, count, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with open(os.path.join(source, "ps-args.txt"), encoding="utf-8") as f:
        args_line = f.readline()
    with open(os.path.join(source, "ps-comm.txt"), encoding="utf-8") as f:
        comm_line = f.readline()
    args_fields = re.match(r"\s*(\S+)(\s+\S+\s+)(\S+)(.*\n?)", args_line)
    comm_fields = re.match(r"\s*(\S+)(.*\n?)", comm_line)
    if args_fields is None or comm_fields is None:
        sys.exit("元の case の 1 行目を読めません: " + source)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "ps-args.txt"), "w", encoding="utf-8") as args_out, open(
        os.path.join(out, "ps-comm.txt"), "w", encoding="utf-8"
    ) as comm_out:
        for i in range(count):
            pid = str(100000 + i)
            args_out.write(pid + args_fields.group(2) + pid + args_fields.group(4))
            comm_out.write(pid + comm_fields.group(2))


if __name__ == "__main__":
    main()
