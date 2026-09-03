#!/usr/bin/env python3
"""pane の生信号を JSON Lines へ記録する (PLAN.md §6.1)。

判定は行わない。分類器は record を後から読む (record once, classify many)。
"""
import json
import os
import subprocess
import sys
import time

SOCKET = os.environ.get("G3_SOCKET", "gate3-spike")

FORMATS = [
    "pane_id", "pane_pid", "pane_tty", "pane_current_command", "pane_current_path",
    "pane_title", "pane_dead", "pane_dead_status", "pane_in_mode", "alternate_on",
    "window_activity", "window_bell_flag", "window_activity_flag", "window_silence",
]
# tmux 3.4 の display-message は制御文字を \\037 のような八進エスケープへ変換して出すため、
# 区切りに 0x1F を使うと復元できない (Issue #72 と同じ性質)。印字可能な区切りを使う。
SEP = "@|@"
FMT = SEP.join("#{%s}" % f for f in FORMATS)


def tmux(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["tmux", "-L", SOCKET, *args], capture_output=True, text=True)


def descendants(pid: int) -> list[dict]:
    """pane_pid 配下のプロセスツリー (S1)。"""
    out = subprocess.run(
        ["ps", "-Ao", "pid=,ppid=,state=,pcpu=,comm="], capture_output=True, text=True
    ).stdout
    rows, children = {}, {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        p, pp, st, cpu, comm = parts
        try:
            p, pp = int(p), int(pp)
        except ValueError:
            continue
        rows[p] = {"pid": p, "ppid": pp, "state": st, "cpu": float(cpu), "comm": comm}
        children.setdefault(pp, []).append(p)
    result, stack = [], list(children.get(pid, []))
    while stack:
        p = stack.pop()
        if p in rows:
            result.append(rows[p])
            stack.extend(children.get(p, []))
    return result


def sample(target: str) -> dict:
    now = time.time()
    r = tmux("list-panes", "-t", target, "-F", FMT)
    rec: dict = {"ts": round(now, 3)}
    if r.returncode != 0:
        rec["error"] = r.stderr.strip()
        return rec
    values = r.stdout.rstrip("\n").split(SEP)
    rec["fmt"] = dict(zip(FORMATS, values))
    try:
        rec["procs"] = descendants(int(rec["fmt"]["pane_pid"]))
    except (ValueError, KeyError):
        rec["procs"] = []
    cap = tmux("capture-pane", "-p", "-t", target)
    rec["screen"] = cap.stdout if cap.returncode == 0 else None
    return rec


def main() -> int:
    target, out_path = sys.argv[1], sys.argv[2]
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.25
    duration = float(sys.argv[4]) if len(sys.argv) > 4 else 60.0
    deadline = time.time() + duration
    with open(out_path, "w", encoding="utf-8") as fh:
        while time.time() < deadline:
            started = time.time()
            fh.write(json.dumps(sample(target), ensure_ascii=False) + "\n")
            fh.flush()
            time.sleep(max(0.0, interval - (time.time() - started)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
