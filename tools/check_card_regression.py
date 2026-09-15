#!/usr/bin/env python3
"""Require complete, unique frames/slots before scoring versioned card labels."""
import json
import math
import statistics
import sys
from pathlib import Path

REGIONS = ("hero.0", "hero.1", "board.0", "board.1", "board.2", "board.3", "board.4")


def evaluate(rows, labels):
    expected_frames = labels["frames"]
    if not isinstance(rows, list) or len(rows) != len(expected_frames):
        raise ValueError(f"Expected exactly {len(expected_frames)} labeled frames")
    names = [row.get("file") if isinstance(row, dict) else None for row in rows]
    if any(not isinstance(name, str) for name in names) or len(set(names)) != len(names):
        raise ValueError("Frame names must be strings and unique")
    if set(names) != set(expected_frames):
        raise ValueError("Input frame set does not match every versioned label")
    for row in rows:
        observations = row.get("cards")
        if not isinstance(observations, list) or len(observations) != len(REGIONS):
            raise ValueError(f"{row['file']}: expected all seven card slots")
        regions = [item.get("region") if isinstance(item, dict) else None for item in observations]
        if any(not isinstance(region, str) for region in regions) or set(regions) != set(REGIONS):
            raise ValueError(f"{row['file']}: card slots must be complete, known and unique")
        milliseconds = row.get("milliseconds")
        if isinstance(milliseconds, bool) or not isinstance(milliseconds, (int, float)) or not math.isfinite(milliseconds) or milliseconds < 0:
            raise ValueError(f"{row['file']}: milliseconds must be finite and nonnegative")
    correct = absent_correct = missed = wrong = false_positive = 0
    failures = []
    for row in rows:
        expected = expected_frames[row["file"]]
        for observation in row["cards"]:
            region = observation["region"]
            truth, prediction = expected.get(region), observation.get("card")
            if truth is None:
                if prediction is None: absent_correct += 1
                else:
                    false_positive += 1
                    failures.append([row["file"], region, None, prediction])
            elif prediction is None:
                missed += 1
                failures.append([row["file"], region, truth, None])
            elif prediction != truth:
                wrong += 1
                failures.append([row["file"], region, truth, prediction])
            else: correct += 1
    return dict(status="FAIL" if failures else "PASS", frames=len(rows), slots=len(rows) * len(REGIONS),
        correct_cards=correct, rejected_occupied_slots=missed, wrong_cards=wrong,
        false_cards_in_empty_slots=false_positive, correct_empty_slots=absent_correct,
        median_milliseconds=statistics.median(r["milliseconds"] for r in rows),
        max_milliseconds=max(r["milliseconds"] for r in rows), failures=failures, scope=labels["scope"])


def main():
    if len(sys.argv) != 2:
        raise ValueError("Usage: check_card_regression.py poker-cards-output.json")
    root = Path(__file__).resolve().parents[1]
    labels = json.loads((root / "fixtures/video-card-labels.json").read_text())
    report = evaluate(json.loads(Path(sys.argv[1]).read_text()), labels)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(json.dumps({"status": "INVALID", "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
