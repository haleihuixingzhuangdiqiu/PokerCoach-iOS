#!/usr/bin/env python3
"""Verify real 5/6 source isolation, current reads, and frozen-reader regression deltas."""
import hashlib
import json
import re
from pathlib import Path

project = Path(__file__).resolve().parents[1]
fixture = project.parents[1] / "work/rank-56-fixtures"
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
baseline_path = fixture / "before-56.json"
template_path = project / "Sources/PokerCoachCapture/Resources/wpk-rank-templates.json"
baseline = json.loads(baseline_path.read_text())
templates = json.loads(template_path.read_text())
assert sha(baseline_path) == "83743b3889746622fa6416b0d02a99aeb74ce242f6c312219986a4a664f8db3b"
assert len(templates) == 23 and templates[:21] == baseline
assert {t["rank"] for t in templates} == set("23456789TJQKA")
five, six = templates[-2:]
assert five["rank"] == "5" and "418cc6d5456ff8e062b38296da1e9a143efa880432ce615a9bed1257c094ce0e" in five["source"]
assert six["rank"] == "6" and "c07cad8e628e58f0ffea5f865f9e26bdfd44db492929d30acf059580f3b4baf3" in six["source"]
assert "c07cad8e628e58f0ffea5f865f9e26bdfd44db492929d30acf059580f3b4baf3" not in five["source"]

rows = json.loads((fixture / "comparison.json").read_text())
old = {r["file"]: r for r in json.loads((fixture / "template-only-comparison.json").read_text())}
expected = {
    "settlement-jd7c-5d4c6d": ["Jd", "7c", "5d", "4c", "6d", None, None],
    "train-5h4h": ["5h", "4h", None, None, None, None, None],
    "holdout-as2c-4sts9d": ["As", "2c", "4s", "Ts", "9d", None, None],
}
screens = []
for base, cards in expected.items():
    for suffix, size in [(".jpg", [1280, 2781]), ("-production.jpg", [663, 1440]), ("-664x1440.jpg", [664, 1440])]:
        row = next(r for r in rows if r["file"] == base + suffix)
        assert [row["width"], row["height"]] == size
        assert [s["after"].get("card") for s in row["slots"]] == cards
        assert not any(s["after"]["hasUnresolvedCard"] for s in row["slots"])
        assert all(s["after"]["reason"] == "字形候选，仍需跨帧确认" for s in row["slots"] if s["after"].get("card"))
        screens.append({"file": row["file"], "sha256": row["sha256"], "size": size,
                       "cards": cards, "matches": {s["region"]: s.get("nearestAfter") for s in row["slots"] if s["after"].get("card")}})

old_frames = [r for r in rows if re.fullmatch(r"\d{4}\.jpg", r["file"])]
assert len(old_frames) == 240
template_only_changes, full_changes, new_accepted = [], [], []
for current in old_frames:
    frozen = old[current["file"]]
    for a, b in zip(frozen["slots"], current["slots"]):
        extract = lambda item: (item.get("card"), item["hasUnresolvedCard"])
        if extract(a["before"]) != extract(a["after"]):
            template_only_changes.append([current["file"], a["region"]])
        if extract(a["before"]) != extract(b["after"]):
            delta = {"file": current["file"], "region": a["region"], "before": a["before"], "after": b["after"]}
            full_changes.append(delta)
            if b["after"].get("card") is not None:
                new_accepted.append(delta)
assert not template_only_changes
assert not new_accepted
assert len(full_changes) == 9
assert {(d["file"], d["region"]) for d in full_changes} == {
    ("0118.jpg", "board.1"), ("0135.jpg", "board.2"), ("0150.jpg", "board.2"),
    ("0150.jpg", "board.3"), ("0151.jpg", "board.3"), ("0152.jpg", "board.3"),
    ("0153.jpg", "board.3"), ("0240.jpg", "board.2"), ("0240.jpg", "board.3")}

labels = json.loads((project / "fixtures/video-card-labels.json").read_text())["frames"]
correct = empty = 0
for name, truth in labels.items():
    row = next(r for r in rows if r["file"] == name)
    for slot in row["slots"]:
        assert slot["after"].get("card") == truth.get(slot["region"]), (name, slot["region"])
        if truth.get(slot["region"]) is None: empty += 1
        else: correct += 1
assert correct == 31 and empty == 25

capture = project / "Sources/PokerCoachCapture"
report = {
    "scope": "Real WPK 5h and 6d training pixels; separate 5d glyph is held out for rank 5. Only one real 6 source, no independent six holdout. Offline BGRA/JPEG and production reader, not live ReplayKit/phone evidence.",
    "template_count": 23, "rank_count": 13,
    "template_sha256": sha(template_path), "baseline_sha256": sha(baseline_path),
    "additions": [{"rank": t["rank"], "source": t["source"]} for t in [five, six]],
    "thresholds": {"maximum_distance": .16, "minimum_rank_margin": .04},
    "reader_source_sha256": {n: sha(capture / n) for n in ["RegionImaging.swift", "RankTemplates.swift", "CardRegionReader.swift"]},
    "frozen_reader_source_sha256": {n: sha(fixture / "source-snapshot" / n) for n in ["RegionImaging.swift", "RankTemplates.swift", "CardRegionReader.swift"]},
    "screens": screens,
    "old_video": {"frames": 240, "slots": 1680, "template_only_changes": template_only_changes,
                  "full_change_deltas": full_changes, "new_or_changed_accepted_cards": new_accepted,
                  "meaning": "No new accepted card values. Two partial-animation cards now rejected; five popup unresolved slots now empty; two Control Center slots now unresolved. Not all 240 frames are independently labeled."},
    "manually_labeled_holdout": {"frames": 8, "correct_cards": correct, "correct_empty_slots": empty},
    "comparison_sha256": sha(fixture / "comparison.json"),
    "template_only_comparison_sha256": sha(fixture / "template-only-comparison.json"),
}
output = project / "reports/genuine-five-six-coverage.json"
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"PASS: 9 screenshot variants; 240-frame template-only unchanged; full reader has 9 reviewed deltas and no new accepted cards; 31 labeled cards and 25 empty slots correct. {output}")
