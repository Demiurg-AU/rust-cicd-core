#!/usr/bin/env bash
# Trusted workflow adapter. The caller's configuration is data, never sourced shell.
set -euo pipefail
TPL="$(cd "$(dirname "$0")/.." && pwd)"
crate="$(cd "${1:?caller checkout}" && pwd)"
src="$crate/${2:-.rcc}"
[ -d "$src/overlay" ] || { echo '::error::RCC missing overlay/'; exit 2; }
# A new directory per invocation prevents old evidence from satisfying the report requirement.
cfg=$(mktemp -d "$TPL/pilots/caller.XXXXXX")
mkdir -p "$cfg/work"
echo "evidence-dir=$cfg/work" >> "$GITHUB_OUTPUT"
bash "$TPL/scripts/pilot-config.sh" "$src/pilot.env" \
  --caller-url "$crate" --caller-sha "$(git -C "$crate" rev-parse HEAD)" --output "$cfg/pilot.env"
cp -r "$src/overlay" "$cfg/overlay"
log="$cfg/pilot.log"
set +e
TMPDIR="$RUNNER_TEMP" bash "$TPL/scripts/pilot.sh" "$cfg" 3a 2>&1 | tee "$log"
status=("${PIPESTATUS[@]}")
set -e
rc=${status[0]}
# Keep diagnostics (including early failures) in the uploaded directory.
mkdir -p "$cfg/work"
cp "$log" "$cfg/work/pilot.log"
if ! python3 "$TPL/scripts/pilot-report.py" "$cfg/work" "$log" "$rc"; then
  echo '::error::RCC pilot did not produce a mandatory completed report for this run'
  [ "$rc" -ne 0 ] || rc=1
fi
if [ "${status[1]}" -ne 0 ] && [ "$rc" -eq 0 ]; then rc=${status[1]}; fi
{
  echo '### rust-cicd-core stage 3a'
  echo
  echo '```'
  grep -E '^  ci-local \(exit|^    (core|canaries|evidence/judge|policy|lean) |^    NOT PASS |^PILOT ' "$log" || true
  echo '```'
  echo "template \`$(git -C "$TPL" rev-parse HEAD)\`, crate \`$(git -C "$crate" rev-parse HEAD)\`, exit $rc"
} >> "$GITHUB_STEP_SUMMARY"
exit "$rc"
