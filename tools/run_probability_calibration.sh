#!/bin/bash
set -euo pipefail

# Pure local mathematical calibration audit: no UI, device, recordings, or network.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${POKER_CALIBRATION_SCRATCH_PATH:-$project_root/work/probability-calibration-build}"
mkdir -p "$scratch/module-cache"
swiftc -O -parse-as-library -swift-version 5 \
  -module-cache-path "$scratch/module-cache" \
  "$project_root/Sources/PokerCoachCore/Cards.swift" \
  "$project_root/Sources/PokerCoachCore/Ranges.swift" \
  "$project_root/Sources/PokerCoachCore/Equity.swift" \
  "$project_root/tools/check_probability_calibration.swift" \
  -o "$scratch/check-probability-calibration"
exec "$scratch/check-probability-calibration" "$@"
