#!/usr/bin/env bash
# E-1 harness: baseline CI and template 3a for each variant (see docs/experiments/baseline-vs-template.md)
set -u
OUT=/root/e1; mkdir -p $OUT; export PATH="$HOME/.elan/bin:$PATH"
for v in "$@"; do
  sha=$(git -C /root/ht-cmp rev-parse $v)
  lock=/home/claude/rust-cicd-core/pilots/humantime/overlay/Cargo.lock; [ $v = R6 ] && lock=/root/cmp-R6.Cargo.lock
  # baseline
  c0=$(awk '/^cpu /{print $2+$3+$4+$7+$8}' /proc/stat)
  B=/root/e1-base-$v; rm -rf $B; git -C /root/ht-cmp worktree remove -f $B 2>/dev/null; git clone -q /root/ht-cmp $B && git -C $B checkout -q $sha && cp $lock $B/Cargo.lock
  ( cd $B && /usr/bin/time -f "TIME wall=%e user=%U sys=%S" bash -c '
      cargo +1.100.0 fmt --check >/dev/null 2>&1 || { echo "BASE FIRST-FAIL fmt"; exit 1; }
      cargo +1.100.0 clippy -q --locked --all-targets -- -D warnings >clippy.log 2>&1 || { echo "BASE FIRST-FAIL clippy"; exit 1; }
      cargo +1.100.0 test -q --locked --all-targets >test.log 2>&1 || { echo "BASE FIRST-FAIL test"; exit 1; }
      cargo +1.100.0 test -q --locked --doc >doc.log 2>&1 || { echo "BASE FIRST-FAIL doctest"; exit 1; }
      echo "BASE PASS"' ) > $OUT/$v.base.txt 2>&1; echo "exit=$?" >> $OUT/$v.base.txt
  c1=$(awk '/^cpu /{print $2+$3+$4+$7+$8}' /proc/stat); echo "CPU-SECONDS $(( (c1-c0)/100 ))" >> $OUT/$v.base.txt
  rm -rf $B/target
  # template 3a
  c0=$(awk '/^cpu /{print $2+$3+$4+$7+$8}' /proc/stat)
  P=/root/pcmp/pilots/cmp-$v; rm -rf $P /root/pcmp/pilots/cmp-$v/work; cp -r /root/pcmp/pilots/humantime $P; rm -rf $P/work
  sed -i "s#^CRATE_URL=.*#CRATE_URL=/root/ht-cmp#; s#^CRATE_SHA=.*#CRATE_SHA=$sha#" $P/pilot.env; cp $lock $P/overlay/Cargo.lock
  ( cd /root/pcmp && EXT_RULES=/root/pol-cmp/rules.json EXT_RULESETS=/root/pol-cmp/rulesets.json LEAN_TOOLCHAIN=lean-4.35.0 \
      /usr/bin/time -f "TIME wall=%e user=%U sys=%S" bash scripts/pilot.sh pilots/cmp-$v 3a ) > $OUT/$v.tmpl.txt 2>&1; echo "exit=$?" >> $OUT/$v.tmpl.txt
  c1=$(awk '/^cpu /{print $2+$3+$4+$7+$8}' /proc/stat); echo "CPU-SECONDS $(( (c1-c0)/100 ))" >> $OUT/$v.tmpl.txt
  grep -E 'CPU-SECONDS|NOT PASS|ci-local \(exit|^TIME|^exit' $OUT/$v.tmpl.txt | head -12 > $OUT/$v.tmpl.sum
  rm -rf $P/work /tmp/rcc.* 2>/dev/null
  echo "$v done $(date -u +%H:%M:%S)" >> $OUT/progress
done
