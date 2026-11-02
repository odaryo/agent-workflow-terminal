#!/usr/bin/env python3
"""PostToolUse (matcher: Bash) フックの判定本体。警告だけを出し、プロセスは止めない。

Bash の呼び出しのたびに ps を取り、「親が 1 / tty を持つ / pgid == pid / comm が tmux でない」
プロセスを、計測用の偽エージェントの孤児の候補として hookSpecificOutput.additionalContext で
知らせる。経緯と機序は Issue #540 / CLAUDE.md「外部 CLI を計測するときの作法」。

**判定できないときは黙る (exit 0・出力なし)。** PreToolUse の guard_bash_tmux.py とは逆向きで
ある。これは警告であり、止める側へ倒す理由が無い。PostToolUse は exit 2 でもツールを止めないが、
exit 0 以外は「hook error」として毎回表示されるので、例外も含めて exit 0 に揃える。

自動で止めないのは、正当な孤児がありうるため (nohup、親が 1 になる隔離 tmux server)。片付けは
孤児を作ったセッション自身に任せる。

既知の穴: 次に Bash を呼ぶまで警告は出ない。隔離 server が生きている間は、session を消した
pane のプロセスの親はまだ tmux server なので候補にならない (実測、Issue #540)。このスクリプトが
無い・実行権が無い・timeout を超えた・python3 が無いときは、何も出ない。subagent の Bash で
渡る session_id が親と子のどちらのものかは未確認なので、session_id では絞らない。

依存は標準ライブラリのみ。macOS の /usr/bin/python3 (3.9) でも動く書き方にする。
"""

import json
import os
import re
import subprocess
import sys

# comm は必ず最後の列で取る。後ろに列を続けると comm が 16 文字 (`/private/tmp/cla`) で切れ、
# args を comm より前に置くと今度は args が切れる (実測 macOS 27)。そのため 2 回に分けて取る。
PS_ARGS_FORMAT = "pid=,ppid=,pgid=,%cpu=,tty=,args="
PS_COMM_FORMAT = "pid=,comm="

# macOS は `??`、Linux の procps は `?` を出す。
NO_TTY = frozenset(("??", "?"))

# 1 件あたり args が数百文字あり、#517 では 120 件残った。文脈を食い潰さないよう打ち切る。
MAX_LISTED = 30
MAX_ARGS_CHARS = 300

# hook の timeout (settings.json で 5 秒) より十分短くする。超えると出力ごと捨てられる。
PS_TIMEOUT_SECONDS = 2


def parse_ps_args(text):
    rows = []
    for line in text.splitlines():
        fields = line.split(None, 5)
        if len(fields) < 6:
            continue
        try:
            row = {
                "pid": int(fields[0]),
                "ppid": int(fields[1]),
                "pgid": int(fields[2]),
                "cpu": float(fields[3]),
                "tty": fields[4],
                "args": fields[5],
            }
        except ValueError:
            continue
        rows.append(row)
    return rows


def parse_ps_comm(text):
    comms = {}
    for line in text.splitlines():
        fields = line.split(None, 1)
        if len(fields) < 2:
            continue
        try:
            comms[int(fields[0])] = fields[1]
        except ValueError:
            continue
    return comms


def find_candidates(args_text, comm_text):
    comms = parse_ps_comm(comm_text)
    candidates = []
    for row in parse_ps_args(args_text):
        comm = comms.get(row["pid"])
        # 2 回の ps の間に終わった (または現れた) もの。comm が分からなければ tmux か判定
        # できないので、推測で候補にしない。
        if comm is None:
            continue
        if row["ppid"] != 1 or row["tty"] in NO_TTY or row["pgid"] != row["pid"]:
            continue
        # comm は argv[0] なので、PATH で起動すれば `tmux`、絶対パスなら `/opt/.../tmux` になる。
        if os.path.basename(comm) == "tmux":
            continue
        candidates.append(row)
    return candidates


def scratchpad_needle(scratchpad_dir):
    """args に含まれていれば scratchpad の印を付ける部分文字列。

    ps の args には起動したときの綴りが現れ、/tmp と /private/tmp のどちらもありうる (macOS の
    /tmp は /private/tmp への symlink)。`/private` を落とした綴りは両方の部分文字列になる。
    """
    base = scratchpad_dir.rstrip("/")
    for full in ("/private/tmp/", "/private/var/"):
        if base.startswith(full):
            base = base[len("/private"):]
    return base + "/" if base else None


def fallback_scratchpad_re(uid):
    # scratchpad_dir は Claude Code v2.1.257 以降にしか無い。それより前は既定の置き場の形で代用する。
    return re.compile(r"(?:/private)?/tmp/claude-%d/[^/\s]+/[^/\s]+/scratchpad/" % uid)


def build_context(candidates, scratchpad_dir, uid):
    needle = scratchpad_needle(scratchpad_dir)
    if needle:

        def marked(args):
            return needle in args

        legend = (
            "[scratchpad] は args がこのセッションの scratchpad (%s) を含むもの。"
            % scratchpad_dir.rstrip("/")
        )
    else:
        pattern = fallback_scratchpad_re(uid)

        def marked(args):
            return pattern.search(args) is not None

        legend = (
            "[scratchpad] は args が Claude Code の scratchpad "
            "(/private/tmp/claude-%d/*/*/scratchpad/) を含むもの。どのセッションのものかは区別できない。"
            % uid
        )

    total_cpu = sum(row["cpu"] for row in candidates)
    listed = candidates[:MAX_LISTED]
    lines = [
        "[孤児プロセスの警告 / Issue #540] 親が 1 で端末 (tty) を持つ session leader が "
        "%d 件残っています (合計 %%cpu %.1f)。" % (len(candidates), total_cpu),
        "計測用の偽エージェントを pane で動かし、kill-session だけで後始末した残骸かもしれません "
        "(HUP を trap したプロセスは kill-session では終わらず、端末が消えた後に空回りする)。",
        "このフックはプロセスを止めない。nohup などの正当な孤児も同じ形でここに現れる。",
        "自分が作ったと確かめられたものだけを止める。ほかのセッションやユーザーのプロセスには触らない。"
        "確かめられないものは止めずに、pid と args をユーザーに報告する。",
        legend + "相対パスで起動したものには印が付かないので、印が無いことは自分のものでない証拠に"
        "ならない。印があることも自分が作った証拠にはならない。",
        "",
    ]
    for row in listed:
        args = row["args"]
        if len(args) > MAX_ARGS_CHARS:
            args = args[:MAX_ARGS_CHARS] + "…"
        mark = " [scratchpad]" if marked(row["args"]) else ""
        lines.append(
            "- pid %d (%%cpu %.1f, %s)%s %s" % (row["pid"], row["cpu"], row["tty"], mark, args)
        )
    if len(candidates) > len(listed):
        lines.append("(ほか %d 件は省略)" % (len(candidates) - len(listed)))
    lines += [
        "",
        "止めるときは、pgid ごとに kill -TERM -- -<pid> を送り、0.5 秒待って残っていれば "
        "kill -KILL -- -<pid> を送り、最後に ps -p <pid> が空なことを確かめる:",
    ]
    lines += ["  kill -TERM -- -%d" % row["pid"] for row in listed]
    return "\n".join(lines)


def run_ps(ps_command, fmt):
    try:
        result = subprocess.run(
            [ps_command, "-A", "-o", fmt],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=PS_TIMEOUT_SECONDS,
            env=dict(os.environ, LC_ALL="C"),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", errors="replace")


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    tool_name = data.get("tool_name")
    if isinstance(tool_name, str) and tool_name != "Bash":
        return 0
    scratchpad_dir = data.get("scratchpad_dir")
    if not isinstance(scratchpad_dir, str):
        scratchpad_dir = ""

    # fixture で検査するための差し替え口 (scripts/check-orphan-warning.sh)。
    ps_command = os.environ.get("AWT_ORPHAN_WARNING_PS") or "/bin/ps"
    args_text = run_ps(ps_command, PS_ARGS_FORMAT)
    if not args_text:
        return 0
    comm_text = run_ps(ps_command, PS_COMM_FORMAT)
    if not comm_text:
        return 0

    candidates = find_candidates(args_text, comm_text)
    if not candidates:
        return 0

    output = json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": build_context(candidates, scratchpad_dir, os.getuid()),
            }
        },
        ensure_ascii=False,
    )
    # 途中まで書いて例外になると壊れた JSON が渡るので、組み立て終えてから 1 回で書く。
    sys.stdout.write(output + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:  # noqa: BLE001 - 警告用なので、判定できないときは黙る側へ倒す
        sys.exit(0)
