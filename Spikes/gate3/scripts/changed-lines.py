#!/usr/bin/env python3
"""真値区間ごとに「1 観測で何行が変わったか」を数える (Issue #203 / README §13)。

`analyze.py` の `truth_intervals()` をそのまま使うので、claude と codex の真値の
非対称 (claude は画面テキスト、codex は pane_title) はそちらの定義に従う。これが
`replay-swift` ではなくここで codex を数える理由で、`replay-swift` の `truthIntervals`
は claude 側だけの移植であり、codex に当てると working / permission の境界が消える。

変化行数は製品の `AgentScreenChangeTracker.changedLineCount` と同じ規則:
両者を "\\n" で分割し、短い側を空行で埋めて **index 単位**で異なる行を数える。
比較対象は常に 1 回前の観測で、「最後に出力と認めた画面」ではない。

`--poll` の意味に注意する。
  0.25 (既定) は記録の分解能そのままで、位相が 1 つしか無いため
        **独立した画面変化イベントの数**が出る。
  2.0   は 8 フレーム間引き。位相 8 通りを合算するので n は最大 8 倍に膨らむ。
        製品の polling 間隔での成績 (`replay-swift --score`) と突き合わせる用。

使い方:
  python3 Spikes/gate3/scripts/changed-lines.py claude
  python3 Spikes/gate3/scripts/changed-lines.py codex
  python3 Spikes/gate3/scripts/changed-lines.py claude --poll 2.0
  python3 Spikes/gate3/scripts/changed-lines.py claude --diffs idle
"""
import argparse
import difflib
import importlib.util
import json
from collections import Counter, defaultdict
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
FRAME_PERIOD = 0.25


def load_analyze():
    spec = importlib.util.spec_from_file_location("analyze", SCRIPTS / "analyze.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def changed_lines(before: str, after: str) -> int:
    a, b = before.split("\n"), after.split("\n")
    n = max(len(a), len(b))
    a += [""] * (n - len(a))
    b += [""] * (n - len(b))
    return sum(1 for i in range(n) if a[i] != b[i])


def rows_of(run_dir: Path) -> list[dict]:
    # recorder が pane を観測できなかったフレームは `fmt` を持たない。Agent の状態では
    # なく記録側の失敗なので、観測が無かったものとして落とす (replay-swift と同じ)。
    lines = (run_dir / "signals.jsonl").read_text().splitlines()
    return [r for r in (json.loads(line) for line in lines) if "fmt" in r]


def walk(rows: list[dict], intervals: list, step: int, guard: float):
    """(真値ラベル, 変化行数, 時刻, 直前画面, 画面) を、間引き位相ごとに全部返す。"""
    for phase in range(step):
        previous = None
        for row in rows[phase::step]:
            screen = row.get("screen")
            if screen is None or row["fmt"].get("pane_dead") == "1":
                previous = None  # 実路も capture 失敗時は forget する
                continue
            before, previous = previous, screen
            if before is None:
                continue
            count = changed_lines(before, screen)
            if count == 0:
                continue
            hit = [iv for iv in intervals if iv[0] <= row["ts"] < iv[1]]
            if not hit:
                continue
            lo, hi, label = hit[0][0], hit[0][1], hit[0][2]
            if row["ts"] - lo < guard or hi - row["ts"] < guard:
                continue
            yield label, count, row["ts"], before, screen


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("agent", choices=["claude", "codex"])
    parser.add_argument("--records", default=str(SCRIPTS.parent / "evidence" / "runs"))
    parser.add_argument("--poll", type=float, default=FRAME_PERIOD)
    parser.add_argument("--diffs", help="この真値ラベルの変化を差分として表示する")
    args = parser.parse_args()

    analyze = load_analyze()
    step = max(1, round(args.poll / FRAME_PERIOD))
    runs = sorted(Path(args.records).glob(f"{args.agent}-composite-r*"))
    if not runs:
        print(f"{args.agent}-composite-r* が無い")
        return 1

    histogram: dict[str, Counter] = defaultdict(Counter)
    for run_dir in runs:
        rows = rows_of(run_dir)
        intervals = analyze.truth_intervals(run_dir, args.agent, rows)
        for label, count, ts, before, screen in walk(rows, intervals, step, analyze.GUARD):
            histogram[label][count] += 1
            if args.diffs == label:
                base = rows[0]["ts"]
                print(f"--- {run_dir.name} t+{ts - base:6.2f}s  変化 {count} 行")
                for line in difflib.unified_diff(
                    before.split("\n"), screen.split("\n"), lineterm="", n=0
                ):
                    if line[:3] not in ("---", "+++"):
                        print(f"    {line}")

    kind = "独立イベント" if step == 1 else f"{step} 位相の合算"
    print(
        f"\n=== {args.agent} 変化行数 ({len(runs)} run / poll {step * FRAME_PERIOD}s"
        f" = {kind} / GUARD {analyze.GUARD}s) ==="
    )
    print("真値\tn\t1行\t内訳")
    for label in sorted(histogram):
        counts = histogram[label]
        total = sum(counts.values())
        one = counts.get(1, 0)
        breakdown = " ".join(f"{k}行:{v}" for k, v in sorted(counts.items()))
        print(f"{label}\t{total}\t{one} ({one / total:.3f})\t{breakdown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
