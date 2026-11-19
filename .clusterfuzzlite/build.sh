#!/bin/bash -eu
# Builds exactly the targets listed in fuzz/fuzz-targets.tsv (the same list fuzz-gate.sh enforces).
cd "$SRC/rust-cicd-core/fuzz"
cargo fuzz build -O
targets="$(awk -F'\t' '!/^#/ && NF {print $1}' fuzz-targets.tsv)"
[ -n "$targets" ] || { echo "CFLITE no target listed in fuzz/fuzz-targets.tsv"; exit 1; }
for t in $targets; do
  cp "target/x86_64-unknown-linux-gnu/release/$t" "$OUT/"
done
