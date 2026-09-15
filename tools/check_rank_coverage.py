#!/usr/bin/env python3
"""Validate a fresh A audit of the current 23-template library, not a historical report."""
import hashlib
import json
import os
import re
from pathlib import Path

def require(condition, reason):
    if not condition:
        raise ValueError(reason)

project = Path(__file__).resolve().parents[1]
fixture_root = Path(os.environ.get("POKER_PRIVATE_FIXTURE_ROOT", project.parents[1] / "work"))
fixture = fixture_root / "rank-coverage-fixtures"
comparison_path = fixture / "comparison-current.json"
manifest_path = fixture / "comparison-current-manifest.json"
require(comparison_path.is_file() and manifest_path.is_file(),
        "Run the freshly compiled audit_rank_coverage.swift audit first; historical comparison.json is not current evidence")
rows = json.loads(comparison_path.read_text())
manifest = json.loads(manifest_path.read_text())
baseline_path = fixture / "wpk-rank-templates-before-a.json"
template_path = project / "Sources/PokerCoachCapture/Resources/wpk-rank-templates.json"
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
baseline = json.loads(baseline_path.read_text())
templates = json.loads(template_path.read_text())
require(sha(baseline_path) == "037e750ce10eee598d36fef63db40658eb9d31748a6a1606e6cc71d20ffb59d0", "Historical baseline changed")
require(templates[:20] == baseline and len(templates) == 23, "Expected the current 23-template library with original 20 preserved")
require({t["rank"] for t in templates} == set("23456789TJQKA"), "Current library must cover all 13 ranks")
aces = [t for t in templates if t["rank"] == "A"]
require(len(aces) == 1, "Expected exactly one A template")
ace = aces[0]
require("bce471dd0cb1a34546ff1e58ec8bf725c011075edb949ff610e974beb057562d" in ace["source"], "A training provenance changed")
require("1344eb0c3f2bb0a0a6d7e4a8338930401f8492348f25af2c5ab30e6e7115a0a5" not in ace["source"], "A holdout entered training")
require(manifest["schemaVersion"] == 1 and manifest["templateSHA256"] == sha(template_path)
        and manifest["baselineSHA256"] == sha(baseline_path)
        and manifest["comparisonSHA256"] == sha(comparison_path), "Audit manifest is stale or mismatched")
reader_sources = {name: sha(project / "Sources/PokerCoachCapture" / name)
                  for name in ["RegionImaging.swift", "RankTemplates.swift", "CardRegionReader.swift"]}
require(manifest["readerSourceSHA256"] == reader_sources, "Reader changed since the audited build; recompile and rerun")

expected = {
    "train-ac-jc": ["Ac", "Jc", None, None, None, None, None],
    "holdout-as-jh-9d": ["Jd", "4d", "As", "Jh", "9d", None, None],
}
labels = json.loads((project / "fixtures/video-card-labels.json").read_text())["frames"]
expected_files = {f"{i:04d}.jpg" for i in range(1, 241)} | set(labels)
expected_files |= {base + suffix for base in expected for suffix in [".png", "-production.jpg", "-664x1440.jpg"]}
require(isinstance(rows, list) and len(rows) == len(expected_files), "Audit must include all 254 unique frames")
names = [row["file"] for row in rows]
require(len(set(names)) == len(names) and set(names) == expected_files, "Audit frames missing, duplicated or unexpected")
regions = ["hero.0", "hero.1", "board.0", "board.1", "board.2", "board.3", "board.4"]
for row in rows:
    require([slot["region"] for slot in row["slots"]] == regions, f"{row['file']}: expected all seven ordered slots")
new_screens = []
for base, cards in expected.items():
    for suffix, size in [(".png", [1320, 2868]), ("-production.jpg", [663, 1440]), ("-664x1440.jpg", [664, 1440])]:
        name = base + suffix
        row = next(r for r in rows if r["file"] == name)
        require([row["width"], row["height"]] == size, f"{name}: wrong dimensions")
        require([s["after"].get("card") for s in row["slots"]] == cards, f"{name}: wrong card readings")
        require(all(s["after"]["reason"] == "字形候选，仍需跨帧确认" for s in row["slots"] if s["after"].get("card")), f"{name}: expected template path")
        ace_slot = row["slots"][0 if base.startswith("train") else 2]
        nearest = ace_slot["nearestAfter"]
        require(nearest["rank"] == "A" and nearest["distance"] <= .16 and nearest["margin"] >= .04, f"{name}: A match failed")
        require(ace_slot["nearestBefore"]["distance"] > .16, f"{name}: baseline no longer reproduces missing A")
        new_screens.append({"file": name, "sha256": row["sha256"], "dimensions": size,
                            "role": "training source or derivative" if base.startswith("train") else "independent holdout or derivative; never used for templates",
                            "cards": cards, "ace_baseline_nearest": ace_slot["nearestBefore"], "ace_updated_nearest": nearest})

old_frames = [row for row in rows if re.fullmatch(r"\d{4}\.jpg", row["file"])]
require(len(old_frames) == 240, "Expected 240 old-video frames")
changes = []
occupied_slots = unresolved_slots = 0
for row in old_frames:
    for slot in row["slots"]:
        a, b = slot["before"], slot["after"]
        if (a.get("card"), a["hasUnresolvedCard"]) != (b.get("card"), b["hasUnresolvedCard"]):
            changes.append([row["file"], slot["region"], a.get("card"), b.get("card")])
        occupied_slots += b.get("card") is not None
        unresolved_slots += b["hasUnresolvedCard"]
require(not changes, "Current-template changes require manual review: " + repr(changes))

correct = empty = 0
for name, truth in labels.items():
    row = next(r for r in rows if r["file"] == name)
    for slot in row["slots"]:
        expected_card = truth.get(slot["region"])
        require(slot["after"].get("card") == expected_card, f"{name}: wrong labeled slot {slot['region']}")
        if expected_card is None:
            empty += 1
        else:
            correct += 1

report = {
    "scope": "Current 23-template library: genuine Ac training and separate As holdout. This audit does not independently validate 5/6; six has no independent holdout. Offline reader/JPEG only, not ReplayKit/device/TCP acceptance.",
    "template_count_before": len(baseline), "template_count_after": len(templates),
    "baseline_template_sha256": sha(baseline_path), "updated_template_sha256": sha(template_path),
    "training_source": ace["source"],
    "covered_ranks": sorted({t["rank"] for t in templates}), "real_template_ranks_still_missing": [],
    "six_independent_holdout": False,
    "thresholds_unchanged": {"maximum_distance": .16, "minimum_other_rank_margin": .04},
    "reader_source_sha256": reader_sources,
    "screenshots": new_screens,
    "old_video_preservation": {"frames": 240, "slots": 1680, "accepted_slots": occupied_slots,
                               "unresolved_slots": unresolved_slots, "changed_cards_or_unresolved_status": changes,
                               "meaning": "No new reading or changed acceptance relative to the saved baseline using the same reader. This comparison is not an independent manual annotation of all 240 frames."},
    "previous_manually_labeled_holdout": {"frames": 8, "correct_occupied_cards": correct, "correct_empty_slots": empty,
                                         "wrong_cards": 0, "missing_cards": 0, "false_cards_in_empty_slots": 0},
    "comparison_sha256": sha(comparison_path),
}
output = project / "reports/ace-template-coverage-current.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"PASS current A audit: 23 templates; 6 screenshot variants, 240 same-reader unchanged old frames, {correct} labeled cards + {empty} empty slots. Six has no independent holdout. Report: {output}")
