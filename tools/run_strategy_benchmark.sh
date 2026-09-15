#!/bin/bash
set -euo pipefail

# Build and run the synthetic paired-deal diagnostic. JSON goes to stdout;
# compiler output goes to stderr. No device or private footage is required.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${POKER_BENCHMARK_SCRATCH_PATH:-$project_root/work/strategy-benchmark-build}"
mkdir -p "$project_root/work"
swift build --package-path "$project_root" --scratch-path "$scratch" -c release >&2
build_bin="$(swift build --package-path "$project_root" --scratch-path "$scratch" -c release --show-bin-path)"
swiftc -O -parse-as-library -swift-version 5 \
  -I "$build_bin/Modules" "$project_root/tools/benchmark_strategy.swift" \
  "$build_bin"/PokerCoachCore.build/*.swift.o \
  -o "$project_root/work/benchmark-strategy"
exec "$project_root/work/benchmark-strategy" "$@"
