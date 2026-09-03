#!/usr/bin/env python3
"""記録済みフレームに分類器を当て、混同行列を出す (PLAN.md §6)。

分類器は recorder が保存した生信号だけを入力にする。記録し直さずに
分類方式を差し替えられるようにしてある (record once, classify many)。
"""
import json
import re
import sys
from pathlib import Path

STATES = ["working", "question", "permission", "completed", "idle", "error", "unknown"]
# 危険な誤判定 = Needs Attention を静かに握りつぶすもの (PLAN.md §6.2)。
NEEDS_ATTENTION = {"question", "permission", "error"}
# "attention" は「注意が要ることは分かるが種別が分からない」という予測値。
# codex の pane_title がまさにこれを返すため、状態語彙とは別に持つ。
SAFE_FOR_ATTENTION = NEEDS_ATTENTION | {"unknown", "attention"}

# 記録から人が確認して決めた境界マーカー (PLAN.md §6.1 の事後レビュー)。
# 画面テキストを根拠にしているため、S2 の precision はこの分だけ楽観側に振れる。
TRUTH_MARKERS = {
    "claude": {
        "permission": re.compile(r"Do you want to |❯ 1\. Yes"),
        "done": re.compile(r"·\s*done\s+\d"),
        "working": re.compile(r"\(\d+s\s*·.*(tokens|esc to interrupt)"),
        "error": re.compile(r"(?i)\b(api error|error:)"),
    },
    "codex": {
        "permission": re.compile(r"Allow .*\?|1\. Yes, (proceed|allow)|Do you want to allow"),
        "done": re.compile(r"^\s*›\s"),
        "working": re.compile(r"(?i)esc to interrupt|Working|Thinking"),
        "error": re.compile(r"(?i)\b(error|failed)\b"),
    },
}


def agent_alive(rec: dict, agent: str) -> bool:
    cmd = rec["fmt"].get("pane_current_command", "")
    names = [p["comm"].rsplit("/", 1)[-1] for p in rec.get("procs", [])]
    if agent == "codex":
        return cmd == "codex" or "codex" in names
    # Claude Code の実体は versions/<版数> という名前のファイルであり、
    # pane_current_command には "claude" ではなく版数文字列が出る (M1 実測)。
    return bool(re.fullmatch(r"\d+\.\d+\.\d+", cmd)) or "claude" in names


# --- 分類器 ---------------------------------------------------------------

# claude が常時抱える子プロセス。turn とは無関係に居る (M1 実測)。
AMBIENT = re.compile(r"(npx|npm|node|caffeinate|mcp|<defunct>|\(.*\))", re.I)


def c_proc_naive(rec, agent, prev):
    """S1 素朴版: 子プロセスが居れば Working。fallback がやりがちな実装。"""
    if not agent_alive(rec, agent):
        return "unknown"
    names = [p["comm"].rsplit("/", 1)[-1] for p in rec.get("procs", [])]
    extra = [n for n in names if agent not in n and not AMBIENT.search(n)]
    return "working" if extra else "idle"


def c_proc_honest(rec, agent, prev):
    """S1 誠実版: プロセス観測だけでは状態を確定できないと認める。"""
    return "unknown" if agent_alive(rec, agent) else "unknown"


def c_activity(rec, agent, prev):
    """S5 window_activity: 直近2秒以内に出力があれば Working。"""
    if not agent_alive(rec, agent):
        return "unknown"
    try:
        act = int(rec["fmt"]["window_activity"])
    except (KeyError, ValueError):
        return "unknown"
    return "working" if rec["ts"] - act <= 2.0 else "idle"


def c_title(rec, agent, prev):
    """S5 pane_title。"""
    if not agent_alive(rec, agent):
        return "unknown"
    title = rec["fmt"].get("pane_title", "")
    if agent == "codex":
        # codex はタイトルへ状態を書く: braille spinner = 実行中、
        # "[ ! ] Action Required" = 利用者の操作待ち (M1/M2 実測)。
        # ただし種別 (permission / question) までは書かないので "attention" に留める。
        if "Action Required" in title:
            return "attention"
        return "working" if re.match(r"[⠀-⣿]", title) else "idle"
    # claude のタイトルは最初のターンで決まるセッション見出しであり、
    # 以降のターンでも更新されない。状態信号ではない (M1/M2 実測)。
    return "unknown"


# すべて記録済みフレームを読んで作った。文言・記号は版数に依存する (PLAN.md §4.2)。
SCREEN_RULES = {
    "claude": [
        ("permission", re.compile(r"Do you want to .*\?")),
        ("question", re.compile(r"(?m)^\s*❯?\s*\d\.\s.*\?\s*$")),
        # 実行中はトークン数カウンタが動く。丸括弧の中身は毎回変わるので当てにしない。
        ("working", re.compile(r"[↓↑]\s*[\d,]+\s*tokens|esc to interrupt")),
        ("error", re.compile(r"(?i)(api error|request failed|error:)")),
        ("completed", re.compile(r"·\s*done\s+\d")),
        # ここまで当たらず Agent の UI 枠だけが見えているなら入力待ち。
        ("idle", re.compile(r"(manual|auto|plan) mode on|accept edits")),
    ],
    "codex": [
        ("permission", re.compile(r"Would you like to|1\. Yes, proceed|Press enter to confirm")),
        ("working", re.compile(r"(?i)esc to interrupt|working\b")),
        ("error", re.compile(r"(?i)(stream error|request failed|error:)")),
        # 起動時の通知も "•" で始まるため、通知行は完了マーカーから除く。
        ("completed", re.compile(r"(?m)^\s*•\s(?!You have|Tip)")),
        ("idle", re.compile(r"Ask Codex to do anything")),
    ],
}


def c_screen(rec, agent, prev):
    """S2 画面テキスト。"""
    if not agent_alive(rec, agent):
        return "unknown"
    s = rec.get("screen") or ""
    for state, pat in SCREEN_RULES[agent]:
        if pat.search(s):
            return state
    return "unknown"


def c_tier_a(rec, agent, ctx):
    """Tier A の組み合わせ。

    種別が要る状態は画面から、実行中かどうかはタイトル / 出力の動きから取る。
    どちらも当たらなければ丸めずに unknown を返す (§12.3)。
    """
    by_screen = c_screen(rec, agent, ctx)
    if by_screen in ("permission", "question", "error"):
        return by_screen
    by_title = c_title(rec, agent, ctx)
    if by_title in ("working", "attention"):
        return by_title
    if c_activity(rec, agent, ctx) == "working":
        return "working"
    return by_screen


# S3 (Tier B): hook イベントの並びから状態を決める。
# Notification は単独では意味が決まらない (permission 待ちでも idle 通知でも出る) ため
# 直前の状態を保持する。payload を読まずに分岐しないこと (PLAN.md §4.3)。
HOOK_STATE = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PermissionRequest": "permission",
    "PostToolUse": "working",
    "Stop": "completed",
    "SessionEnd": "unknown",
}


def c_hooks(rec, agent, ctx):
    events = (ctx or {}).get("hooks") or []
    state = "unknown"
    for e in events:
        if e["ts"] > rec["ts"]:
            break
        state = HOOK_STATE.get(e["event"], state)
    return state


CLASSIFIERS = {
    "S1-proc-naive": c_proc_naive,
    "S1-proc-honest": c_proc_honest,
    "S5-activity": c_activity,
    "S5-title": c_title,
    "S2-screen": c_screen,
    "TierA-combined": c_tier_a,
    "S3-hooks": c_hooks,
}


# --- ground truth ---------------------------------------------------------

SPINNER = re.compile(r"^[⠀-⣿]")


def truth_intervals(run_dir: Path, agent: str, rows: list[dict]) -> list[tuple]:
    """script の事実 (truth.jsonl) と、事後レビューで確認した境界から真値区間を作る。

    真値の出どころが Agent ごとに違う。**この非対称は結果の読み方に効く**:
      - claude: 画面テキスト (完了マーカーの出現回数が増えた最初のフレーム)。
        直前ターンのマーカーが画面に残るため単純な有無では取れない。
        よって S2-screen の claude 側 precision は楽観側へ振れる。
      - codex: pane_title (spinner / "Action Required")。画面には実行中を示す印が
        出ないため画面からは境界を切れない。よって S5-title の codex 側は
        **測定値ではなく真値の定義そのもの**であり、recall を成績として読んではならない。
    """
    ev = {}
    for line in (run_dir / "truth.jsonl").read_text().splitlines():
        e = json.loads(line)
        ev.setdefault(e["event"], e["ts"])
    m = TRUTH_MARKERS[agent]

    def frames(after, before=None):
        return [r for r in rows if r["ts"] >= after and (before is None or r["ts"] < before)]

    def first_match(pat, after, before=None):
        for r in frames(after, before):
            if pat.search(r.get("screen") or ""):
                return r["ts"]
        return None

    def first_increase(pat, after, before=None):
        seq = frames(after, before)
        if not seq:
            return None
        base = len(pat.findall(seq[0].get("screen") or ""))
        for r in seq[1:]:
            if len(pat.findall(r.get("screen") or "")) > base:
                return r["ts"]
        return None

    def title_attention(after, before=None):
        for r in frames(after, before):
            if "Action Required" in r["fmt"].get("pane_title", ""):
                return r["ts"]
        return None

    def spinner_end(after, before=None):
        """spinner が付いてから、2 フレーム続けて外れた最初の時刻。"""
        seen = False
        off = 0
        for r in frames(after, before):
            if SPINNER.match(r["fmt"].get("pane_title", "")):
                seen, off = True, 0
                continue
            if seen:
                off += 1
                if off >= 2:
                    return r["ts"]
        return None

    def turn_end(after, before=None):
        return spinner_end(after, before) if agent == "codex" else first_increase(m["done"], after, before)

    def permission_start(after, before=None):
        return title_attention(after, before) if agent == "codex" else first_match(m["permission"], after, before)

    out = []
    if "prompt_long_sent" not in ev:
        return out
    out.append((ev["idle_begin"], ev["prompt_long_sent"], "idle"))
    done1 = turn_end(ev["prompt_long_sent"], ev.get("prompt_perm_sent"))
    if done1:
        out.append((ev["prompt_long_sent"], done1, "working"))
        out.append((done1, ev["prompt_perm_sent"], "completed"))
    perm = permission_start(ev["prompt_perm_sent"], ev.get("approve_sent"))
    if perm:
        out.append((ev["prompt_perm_sent"], perm, "working"))
        out.append((perm, ev["approve_sent"], "permission"))
        done2 = turn_end(ev["approve_sent"], ev.get("quiesce"))
        if done2:
            out.append((ev["approve_sent"], done2, "working"))
            out.append((done2, ev["quiesce"], "completed"))
    if "quiesce" in ev and "run_end" in ev:
        out.append((ev["quiesce"], ev["run_end"], "completed-left"))
    return out


GUARD = 1.0  # 境界前後は判定不能として集計から外す (PLAN.md §6.1)


def metrics(dist: dict) -> dict:
    n = sum(dist.values())
    return {"n": n, "dist": dict(sorted(dist.items(), key=lambda kv: -kv[1]))}


def main() -> int:
    run_dirs = [Path(p) for p in sys.argv[1:]]
    tally: dict = {}
    excluded = total = 0
    for run_dir in run_dirs:
        agent = run_dir.name.split("-")[0]
        if agent not in TRUTH_MARKERS:
            continue
        rows = [json.loads(l) for l in (run_dir / "signals.jsonl").read_text().splitlines() if l.strip()]
        hooks_path = run_dir / "hook-events.jsonl"
        ctx = {"hooks": [json.loads(l) for l in hooks_path.read_text().splitlines() if l.strip()]
               if hooks_path.exists() else []}
        for a, b, label in truth_intervals(run_dir, agent, rows):
            for r in rows:
                if not (a <= r["ts"] < b):
                    continue
                total += 1
                if r["ts"] - a < GUARD or b - r["ts"] < GUARD:
                    excluded += 1
                    continue
                for name, fn in CLASSIFIERS.items():
                    pred = fn(r, agent, ctx)
                    key = (agent, name, label)
                    tally.setdefault(key, {}).setdefault(pred, 0)
                    tally[key][pred] += 1

    report = {}
    for (agent, clf, label), dist in sorted(tally.items()):
        n = sum(dist.values())
        hit = dist.get(label.replace("-left", ""), 0)
        unk = dist.get("unknown", 0)
        danger = attention = 0
        if label.replace("-left", "") in NEEDS_ATTENTION:
            danger = sum(v for k, v in dist.items() if k not in SAFE_FOR_ATTENTION)
            attention = sum(v for k, v in dist.items() if k in NEEDS_ATTENTION | {"attention"})
        report.setdefault(agent, {}).setdefault(clf, {})[label] = {
            "n": n,
            "recall": round(hit / n, 3) if n else None,
            "unknown_rate": round(unk / n, 3) if n else None,
            "dangerous_rate": round(danger / n, 3) if n else None,
            "attention_rate": round(attention / n, 3) if n else None,
            "dist": dict(sorted(dist.items(), key=lambda kv: -kv[1])),
        }
    print(json.dumps({
        "runs": sorted(d.name for d in run_dirs),
        "frames_scored": total - excluded,
        "frames_excluded_guard": excluded,
        "report": report,
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
