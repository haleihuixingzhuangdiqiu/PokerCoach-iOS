#!/bin/bash
set -euo pipefail

# Offline synthetic research only. No accounts, network, device or private logs.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$project_root/artifacts/training/2026-09-17-continuation}"
build_dir="$project_root/work/continuation-training-build"
mkdir -p "$build_dir" "$output_dir"
if [[ -e "$output_dir/preregistered-plan.json" ]]; then
  echo 'Refusing to overwrite a preregistered experiment. Use a new output directory; do not reuse its test seeds for selection.' >&2
  exit 2
fi
python3 - "$project_root" "$output_dir/source-manifest.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
paths = sorted((root/'Sources/PokerCoachCore').glob('*.swift')) + [root/'tools/train_continuation.swift', root/'tools/run_continuation_training.sh']
files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
aggregate = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
manifest = {'sha256': aggregate, 'files': files, 'baseCommit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(), 'swiftVersion': subprocess.check_output(['swiftc', '--version'], text=True).strip()}
pathlib.Path(sys.argv[2]).write_text(json.dumps(manifest, indent=2, sort_keys=True)+'\n')
PY
swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 \
  -module-cache-path "$build_dir/module-cache" \
  "$project_root"/Sources/PokerCoachCore/*.swift "$project_root/tools/train_continuation.swift" \
  -o "$build_dir/train-continuation"
nice -n 10 "$build_dir/train-continuation" --output "$output_dir"
# Preserve every paired rotation but keep the public research artifact small.
gzip -n "$output_dir/paired-hands.csv"
