#!/usr/bin/env python3
"""Independently recompute saved training aggregates; never rerun/unseal poker test."""
import collections
import csv
import gzip
import hashlib
import json
import math
import pathlib
import statistics
import sys

root = pathlib.Path(__file__).resolve().parents[1]
folder = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'artifacts/training/2026-09-17-continuation'
plan = json.loads((folder / 'preregistered-plan.json').read_text())
report = json.loads((folder / 'report.json').read_text())
manifest = json.loads((folder / 'source-manifest.json').read_text())
for relative, expected in manifest['files'].items():
    assert hashlib.sha256((root / relative).read_bytes()).hexdigest() == expected, relative
aggregate = hashlib.sha256(json.dumps(manifest['files'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()
assert aggregate == manifest['sha256'] == report['source']['sha256']
groups = collections.defaultdict(list)
seeds = collections.defaultdict(set)
seed_by_cluster = {}
seen_rows = set()
count = 0
with gzip.open(folder / 'paired-hands.csv.gz', 'rt', newline='') as stream:
    for row in csv.DictReader(stream):
        split, candidate, scenario = row['split'], row['candidate'], row['scenario']
        cluster, rotation, seed = int(row['cluster']), int(row['rotation']), int(row['dealSeed'])
        key = (split, candidate, scenario, cluster, rotation)
        assert key not in seen_rows, key
        seen_rows.add(key)
        group = (split, candidate, scenario, cluster)
        groups[group].append((rotation, float(row['differenceBB'])))
        expected = (int(row['heroProfitChips']) - int(row['neutralProfitChips'])) / 50
        assert abs(expected - float(row['differenceBB'])) < 1e-12
        if candidate == plan['baseline']['id']:
            assert expected == 0
        seed_key = (split, scenario, cluster)
        assert seed_by_cluster.setdefault(seed_key, seed) == seed
        seeds[split].add(seed)
        count += 1
assert not seeds['train'] & seeds['validation']
assert not seeds['train'] & seeds['test']
assert not seeds['validation'] & seeds['test']
assert len(seed_by_cluster) == len(set(seed_by_cluster.values())) == report['uniqueDealSeedsAcrossSplits']
computed = collections.defaultdict(lambda: collections.defaultdict(list))
for (split, candidate, scenario, cluster), values in sorted(groups.items()):
    players = int(scenario.split('-')[0][1:])
    assert sorted(rotation for rotation, _ in values) == list(range(players))
    computed[(split, candidate)][scenario].append(statistics.mean(value for _, value in values))
means = {}
for (split, candidate), scenarios in computed.items():
    assert len(scenarios) == 12
    means[(split, candidate)] = statistics.mean(statistics.mean(values) for values in scenarios.values())
    file_name = {'train': 'train-scores.json', 'validation': 'validation-scores.json', 'test': 'test-score.json'}[split]
    recorded = json.loads((folder / file_name).read_text())
    if split != 'test':
        recorded = recorded[candidate]
    for scenario, values in scenarios.items():
        assert len(values) == len(recorded['clusterMeansBB'][scenario])
        assert all(abs(a - b) < 1e-10 for a, b in zip(values, recorded['clusterMeansBB'][scenario]))
selected = report['selected']['id']
assert means[('validation', selected)] == max(value for (split, _), value in means.items() if split == 'validation')
assert len([key for key in computed if key[0] == 'test']) == 1
assert abs(means[('test', selected)] * 100 - report['testPairedDifferenceBBPer100']) < 1e-10
test = computed[('test', selected)]
standard_error = math.sqrt(sum(statistics.variance(values) / len(values) for values in test.values())) / len(test)
mean = means[('test', selected)]
assert count == report['totalPairedCandidateRotations']
audit = {'verified': True, 'rawPairedRows': count, 'uniqueDealSeeds': len(seed_by_cluster),
         'completeRotationBlocks': len(groups), 'sourceManifestMatches': True,
         'testCandidateCount': 1, 'selectedCandidate': selected, 'recomputedTestDifferenceBBPer100': mean * 100,
         'independentNormalApprox95BBPer100': [(mean - 1.96 * standard_error) * 100, (mean + 1.96 * standard_error) * 100],
         'note': 'Recomputes saved raw outcomes, not a second poker test or an independent rules/strength oracle.'}
(folder / 'artifact-audit.json').write_text(json.dumps(audit, indent=2, sort_keys=True) + '\n')
print(json.dumps(audit, indent=2, sort_keys=True))
