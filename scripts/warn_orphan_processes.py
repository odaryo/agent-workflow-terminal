#!/usr/bin/env python3
"""PostToolUse / PostToolUseFailure (matcher: Bash) フックの判定本体。警告だけを出し、止めない。

Bash の呼び出しが終わるたびに ps を取り、計測用の偽エージェントの孤児の候補を
hookSpecificOutput.additionalContext で知らせる。経緯と機序は Issue #540 /
CLAUDE.md「外部 CLI を計測するときの作法」。候補は 2 種類ある。

- 種類 A: 親が 1 / tty を持つ / pgid == pid / comm が tmux でない。pane のコマンドとして exec した
  偽エージェントが、session と server が消えた後に残った形。
- 種類 B: 親が 1 / tty が ?? / pgid == pid / 自分の uid / %cpu 50 以上 / comm が tmux でない /
  args が macOS のアプリや常駐の置き場でない。pane の対話 shell から起動した偽エージェントは
  job control で自分の pgid を持ち、shell が消えると tty を失って空回りする (実測 bash 3.2 / zsh)。

PostToolUse は Bash が成功したときだけ、PostToolUseFailure は失敗したときだけ発火する (公式 hooks
ドキュメント)。後始末の確認の `ps -p` は対象が無いと exit 1 になるので、両方に登録している。

**判定できないときは黙る (exit 0・出力なし)。** PreToolUse の guard_bash_tmux.py とは逆向きで
ある。これは警告であり、止める側へ倒す理由が無い。exit 0 以外は「hook error」として毎回表示
されるので、例外も含めて exit 0 に揃える。

自動で止めないのは、正当な孤児がありうるため (nohup、親が 1 になる隔離 tmux server、種類 B の
条件に当たる常駐)。片付けは孤児を作ったセッション自身に任せる。

既知の穴: 次に Bash を呼ぶまで警告は出ない。隔離 server が生きている間は、session を消した
pane のプロセスの親はまだ tmux server なので候補にならない。tty を失って %cpu が 50 未満の
孤児も候補にならない。このスクリプトが無い・実行権が無い・timeout を超えた・python3 が無い
ときは、何も出ない。subagent の Bash で渡る session_id が親と子のどちらのものかは未確認なので、
session_id では絞らない。

依存は標準ライブラリのみ。macOS の /usr/bin/python3 (3.9) でも動く書き方にする。
"""

import json
import os
import re
import subprocess
import sys
import time

# comm は必ず最後の列で取る。後ろに列を続けると comm が 16 文字 (`/private/tmp/cla`) で切れ、
# args を comm より前に置くと今度は args が切れる (実測 macOS 27)。そのため 2 回に分けて取る。
PS_ARGS_FORMAT = "pid=,ppid=,pgid=,uid=,%cpu=,tty=,args="
PS_COMM_FORMAT = "pid=,comm="

# macOS は `??`、Linux の procps は `?` を出す。
NO_TTY = frozenset(("??", "?"))

# 種類 B だけに課す条件。macOS のアプリと常駐は親が 1・tty が ?? の session leader として
# 動くので、CPU と置き場で除く。
B_MIN_CPU = 50.0
B_EXCLUDED_ARGS_PREFIXES = ("/System/", "/usr/libexec/", "/usr/sbin/", "/Library/")
B_EXCLUDED_ARGS_PARTS = (".app/",)

# Python の int() は `7_8873` も `+5` も通すので、列の形は正規表現で先に確かめる。
# %cpu の float() は `nan` / `inf` も通す。
_ID_RE = re.compile(r"^[0-9]{1,10}$")
_CPU_RE = re.compile(r"^[0-9]{1,5}(?:\.[0-9]+)?$")

# Claude Code は additionalContext が 10,000 字を超えるとファイルへ逃がし、先頭 2,000 字の
# preview しか見せない (公式 hooks ドキュメント)。#517 と同じ 120 件で 10,589 字になった。
# 余裕を持たせて 8,000 字に収め、件数と止め方を先頭に置く。単位は文字数。
CONTEXT_BUDGET_CHARS = 8000
MAX_ARGS_CHARS = 200

# 2 回の ps で共有する期限。hook の timeout (settings.json で 5 秒) を超えると出力ごと捨てられる。
PS_DEADLINE_SECONDS = 3.5


def parse_ps_args(text):
    rows = []
    for line in text.splitlines():
        fields = line.split(None, 6)
        if len(fields) < 7:
            continue
        pid, ppid, pgid, uid, cpu, tty, args = fields
        if not all(_ID_RE.match(value) for value in (pid, ppid, pgid, uid)):
            continue
        if not _CPU_RE.match(cpu):
            continue
        rows.append({
            "pid": int(pid),
            "ppid": int(ppid),
            "pgid": int(pgid),
            "uid": int(uid),
            "cpu": float(cpu),
            "tty": tty,
            "args": args,
        })
    return rows


def parse_ps_comm(text):
    comms = {}
    for line in text.splitlines():
        fields = line.split(None, 1)
        if len(fields) < 2 or not _ID_RE.match(fields[0]):
            continue
        comms[int(fields[0])] = fields[1]
    return comms


def classify(row, comm, uid):
    """種類 A なら "A"、種類 B なら "B"、候補でなければ None。"""
    if row["ppid"] != 1 or row["pgid"] != row["pid"]:
        return None
    # comm は argv[0] なので、PATH で起動すれば `tmux`、絶対パスなら `/opt/.../tmux` になる。
    if os.path.basename(comm) == "tmux":
        return None
    if row["tty"] not in NO_TTY:
        return "A"
    if row["uid"] != uid or row["cpu"] < B_MIN_CPU:
        return None
    args = row["args"]
    if args.startswith(B_EXCLUDED_ARGS_PREFIXES):
        return None
    if any(part in args for part in B_EXCLUDED_ARGS_PARTS):
        return None
    return "B"


def find_candidates(args_text, comm_text, uid):
    comms = parse_ps_comm(comm_text)
    found = {"A": [], "B": []}
    for row in parse_ps_args(args_text):
        comm = comms.get(row["pid"])
        # 2 回の ps の間に終わった (または現れた) もの。comm が分からなければ tmux か判定
        # できないので、推測で候補にしない。
        if comm is None:
            continue
        kind = classify(row, comm, uid)
        if kind is not None:
            row["kind"] = kind
            found[kind].append(row)
    return found["A"] + found["B"]


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

    count_a = sum(1 for row in candidates if row["kind"] == "A")
    count_b = len(candidates) - count_a
    total_cpu = sum(row["cpu"] for row in candidates)
    head = [
        "[孤児プロセスの警告 / Issue #540] 計測用の偽エージェントの残骸かもしれないプロセスが "
        "%d 件あります (合計 %%cpu %.1f)。" % (len(candidates), total_cpu),
    ]
    if count_a:
        head.append("- 種類 A (%d 件): 親が 1 で端末 (tty) を持つ session leader。" % count_a)
    if count_b:
        head.append(
            "- 種類 B (%d 件): 端末を失った高 CPU の孤児 (親が 1・tty が ??・pgid == pid・自分の uid・"
            "%%cpu %d 以上)。正当な常駐の可能性もある。" % (count_b, B_MIN_CPU)
        )
    head += [
        "HUP を trap した偽エージェントは kill-session では終わらず、端末が消えた後に空回りする。",
        "このフックはプロセスを止めない。nohup などの正当な孤児もここに現れうる。",
        "自分が作ったと確かめられたものだけを止める。ほかのセッションやユーザーのプロセスには触らない。"
        "確かめられないものは止めずに、pid と args をユーザーに報告する。",
        "止め方: pgid ごとに kill -TERM -- -<pid> を送り、0.5 秒待って残っていれば "
        "kill -KILL -- -<pid> を送り、最後に ps -p <pid> が空なことを確かめる。",
        legend + "相対パスで起動したものには印が付かないので、印が無いことは自分のものでない証拠に"
        "ならない。印があることも自分が作った証拠にはならない。",
        "",
        "止めるコマンド (下の一覧で自分のものと確かめてから):",
    ]

    kill_lines = []
    list_lines = []
    # 載せきれなかった件数の行と、一覧の見出しの分を先に取っておく。
    used = len("\n".join(head)) + len("\n\n一覧:\n") + len("\n(ほか %d 件は字数の上限のため省略)" % len(candidates))
    for row in candidates:
        args = row["args"]
        if len(args) > MAX_ARGS_CHARS:
            args = args[:MAX_ARGS_CHARS] + "…"
        place = row["tty"] if row["kind"] == "A" else "端末なし"
        mark = " [scratchpad]" if marked(row["args"]) else ""
        kill_line = "  kill -TERM -- -%d" % row["pid"]
        list_line = "- pid %d (%%cpu %.1f, %s)%s %s" % (row["pid"], row["cpu"], place, mark, args)
        cost = len(kill_line) + len(list_line) + 2
        if used + cost > CONTEXT_BUDGET_CHARS:
            break
        used += cost
        kill_lines.append(kill_line)
        list_lines.append(list_line)

    lines = head + kill_lines + ["", "一覧:"] + list_lines
    if len(list_lines) < len(candidates):
        lines.append("(ほか %d 件は字数の上限のため省略)" % (len(candidates) - len(list_lines)))
    return "\n".join(lines)


def run_ps(ps_command, fmt, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    try:
        result = subprocess.run(
            [ps_command, "-A", "-o", fmt],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=remaining,
            env=dict(os.environ, LC_ALL="C"),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", errors="replace")


def own_uid():
    # fixture で検査するための差し替え口 (fixture は uid 501 で取った。scripts/check-orphan-warning.sh)。
    override = os.environ.get("AWT_ORPHAN_WARNING_UID", "")
    if _ID_RE.match(override):
        return int(override)
    return os.getuid()


def main():
    deadline = time.monotonic() + PS_DEADLINE_SECONDS
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        return 0
    if not isinstance(data, dict):
        return 0
    tool_name = data.get("tool_name")
    if isinstance(tool_name, str) and tool_name != "Bash":
        return 0
    event_name = data.get("hook_event_name")
    if not isinstance(event_name, str) or not event_name:
        event_name = "PostToolUse"
    scratchpad_dir = data.get("scratchpad_dir")
    if not isinstance(scratchpad_dir, str):
        scratchpad_dir = ""

    # fixture で検査するための差し替え口 (scripts/check-orphan-warning.sh)。
    ps_command = os.environ.get("AWT_ORPHAN_WARNING_PS") or "/bin/ps"
    args_text = run_ps(ps_command, PS_ARGS_FORMAT, deadline)
    if not args_text:
        return 0
    comm_text = run_ps(ps_command, PS_COMM_FORMAT, deadline)
    if not comm_text:
        return 0

    uid = own_uid()
    candidates = find_candidates(args_text, comm_text, uid)
    if not candidates:
        return 0

    output = json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": event_name,
                "additionalContext": build_context(candidates, scratchpad_dir, uid),
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
