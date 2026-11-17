#!/usr/bin/env bash
# Minimal Rust CI core, steps S0-S2 + gate self-test (canaries).
# Every step writes a log; results.tsv is the witness table. NO_WITNESS -> NO_CLOSE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EV="$ROOT/evidence/$STAMP"
mkdir -p "$ROOT/evidence"
mkdir "$EV" || { echo "witness directory unavailable: $EV" >&2; exit 1; }
RES="$EV/results.tsv"
printf 'id\tstep\texpect\texit\treason_check\tverdict\n' > "$RES"
export CARGO_TERM_COLOR=never
# Build outputs live OUTSIDE the repo/evidence folder: evidence holds only logs,
# and the run does not depend on being allowed to delete files in the project folder.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rust-cicd-core.XXXXXX")"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORK/target}"

# --- environment witness ---
{
  echo "utc=$STAMP"; uname -a
  for t in cargo rustc cargo-clippy rustfmt cargo-nextest cargo-llvm-cov cargo-deny cargo-audit; do
    p="$(command -v "$t" || true)"
    if [ -z "$p" ]; then echo "$t: MISSING"; continue; fi
    # rustup installs identical proxy shims; hash the real toolchain binary instead
    real="$p"; command -v rustup >/dev/null && real="$(rustup which "$t" 2>/dev/null || echo "$p")"
    case "$t" in cargo-*) ver="$(cargo "${t#cargo-}" --version 2>&1 | head -1)";; *) ver="$("$t" --version 2>&1 | head -1)";; esac
    echo "$t: $ver | sha256=$(sha256sum "$real" | cut -c1-64)"
  done
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || echo none)"
  echo "cargo_lock_sha256=$(sha256sum Cargo.lock 2>/dev/null | cut -c1-64)"
} > "$EV/env.txt" 2>&1

# run <id> <name> <expect:pass|fail> <reason-regex-or-dash> <workdir> <cmd...>
run() {
  local id="$1" name="$2" expect="$3" rx="$4" wd="$5"; shift 5
  local log="$EV/$id-$name.log" output="$WORK/$id.output" code
  if ( cd "$wd" && "$@" ) > "$output" 2>&1; then code=0; else code=$?; fi
  { printf '$'; printf ' %q' "$@"; printf '\n'; cat "$output"; } > "$log"
  local rc="n/a" verdict
  if [ "$expect" = pass ]; then
    [ $code -eq 0 ] && verdict=PASS || verdict=FAIL
  else
    if [ $code -ne 0 ] && grep -Eq "$rx" "$output"; then rc=matched; verdict=PASS
    elif [ $code -ne 0 ]; then rc=unmatched; verdict=FAIL_WRONG_REASON
    else verdict=FAIL_GATE_DID_NOT_FIRE; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$expect" "$code" "$rc" "$verdict" >> "$RES"
  echo "[$verdict] $id $name (exit $code)"
}

lean_project() {
  local files
  files="$(find "$1" -type d \( -name .lake -o -name .git -o -name evidence -o -name target -o -path "$1/fixtures" \) -prune -o -type f -name lakefile.toml -print)" ||
    { echo "LEAN project discovery failed"; return 1; }
  [ -n "$files" ] || { echo "LEAN project missing"; return 1; }
  [[ "$files" != *$'\n'* ]] || { echo "LEAN multiple projects: $files"; return 1; }
  printf '%s\n' "$files"
}
# Python for the Lean config parser (tomllib) must be >= PY_MIN (default 3.11); checked by L00.
py_check() {
  local py="${PY:-python3}" min="${PY_MIN:-3.11}"
  command -v "$py" >/dev/null || { echo "PYTHON missing: $py"; return 1; }
  "$py" - "$min" <<'PY'
import sys
want = tuple(int(x) for x in sys.argv[1].split("."))
have = sys.version_info[:len(want)]
if have < want:
    print(f"PYTHON too old: {sys.version.split()[0]} < {sys.argv[1]} (tomllib needed)"); sys.exit(1)
import tomllib  # noqa: F401
print(f"python ok: {sys.version.split()[0]}")
PY
}
# lean_mode: prints "run" or "skip". Skipping is allowed ONLY when no Lean project exists AND REQUIRE_LEAN=0.
lean_mode() {
  local out
  case "${REQUIRE_LEAN:-1}" in 0|1) ;; *) echo "REQUIRE_LEAN must be 0 or 1, got: ${REQUIRE_LEAN}"; return 1;; esac
  if out="$(lean_project "$1")"; then echo run; return 0; fi
  if [ "$out" = "LEAN project missing" ] && [ "${REQUIRE_LEAN:-1}" = 0 ]; then echo skip; return 0; fi
  echo "$out"; return 1
}
lean_text() {
  local files file code count=0
  files="$(find "$1" -type d -name .lake -prune -o -type f -name '*.lean' -print)" ||
    { echo "LEAN source discovery failed"; return 1; }
  [ -n "$files" ] || { echo "LEAN sources missing"; return 1; }
  while IFS= read -r file; do
    count=$((count + 1))
    if grep -nE '\b(sorry|admit)\b' "$file"; then
      echo "LEAN forbidden proof text: $file"; return 1
    else
      code=$?
      [ "$code" -eq 1 ] || { echo "LEAN source scan failed: $file"; return 1; }
    fi
  done <<< "$files"
  [ "$count" -gt 0 ]
}
lean_modules() {
  "$PY" - "$@" <<'PY'
import os
from pathlib import Path
import re
import sys
import tomllib

def walk_error(error):
    raise error

try:
    project = Path(sys.argv[1]).resolve()
    with (project / "lakefile.toml").open("rb") as f:
        config = tomllib.load(f)
    libraries = config.get("lean_lib", [])
    if not libraries:
        raise ValueError("no lean_lib in lakefile.toml")
    modules = set()
    module_sources = {}
    for lib in libraries:
        source = (project / config.get("srcDir", ".") / lib.get("srcDir", ".")).resolve()
        source.relative_to(project)
        if not source.is_dir():
            raise ValueError(f"source directory missing: {source}")
        roots = lib.get("roots", [lib["name"]])
        globs = lib.get("globs", roots)
        if not roots or not globs:
            raise ValueError(f"empty library roots/globs: {lib['name']}")
        def in_library(module):
            return any(module == r or module.startswith(r + ".") for r in roots) or any(
                (module == g[:-2] or module.startswith(g[:-1])) if g.endswith(".*")
                else module.startswith(g[:-1]) if g.endswith(".+")
                else module == g for g in globs
            )
        found = set()
        # Include unimported submodules as well as custom roots and globs.
        for directory, dirs, files in os.walk(source, onerror=walk_error):
            dirs[:] = sorted(d for d in dirs if d not in {".lake", ".git"})
            if any((Path(directory) / d).is_symlink() for d in dirs):
                raise ValueError(f"symlinked source directory: {directory}")
            for filename in sorted(files):
                if not filename.endswith(".lean") or filename == "lakefile.lean":
                    continue
                module = ".".join((Path(directory) / filename).relative_to(source).with_suffix("").parts)
                if not in_library(module):
                    continue
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_']*(\.[A-Za-z_][A-Za-z0-9_']*)*", module):
                    raise ValueError(f"unsupported module name: {module}")
                path = (Path(directory) / filename).resolve()
                if module in module_sources and module_sources[module] != path:
                    raise ValueError(f"ambiguous module source: {module}")
                module_sources[module] = path
                found.add(module)
        if not found:
            raise ValueError(f"no Lean source modules for library: {lib['name']}")
        modules.update(found)
    if len(sys.argv) > 2 and sys.argv[2] == "paths":
        print("\n".join(f"{m}\t{module_sources[m].relative_to(project)}" for m in sorted(modules)))
    else:
        print("\n".join(sorted(modules)))
except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
    sys.exit(f"AUDIT module discovery failed: {error}")
PY
}
lean_build() {
  local d="$1" mods m
  mods="$(lean_modules "$d")" || return 2
  [ -n "$mods" ] || { echo "AUDIT no build modules"; return 2; }
  local targets=()
  for m in $mods; do targets+=("+$m"); done
  ( cd "$d" && "${LX[@]}" lake build "${targets[@]}" )
}
lean_version() {
  local version
  version="$("${LX[@]}" lean --version 2>&1)" ||
    { echo "LEAN version command failed: $version"; return 1; }
  printf '%s\n' "$version"
  grep -Fq "version ${1##*:v}," <<< "$version" ||
    { echo "LEAN version does not match pin: $1"; return 1; }
}
pm_tests() {
  local line th t out count=0
  [[ -f "$1" && -r "$1" ]] || { echo 'proof-map missing/unreadable'; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" = \#* || ! "$line" =~ [^[:space:]] ]] && continue
    [[ "$line" = *$'\t'* ]] || { echo "proof-map malformed row: $line"; return 1; }
    th="${line%%$'\t'*}"; t="${line#*$'\t'}"
    [[ "$th" =~ [^[:space:]] && "$t" =~ [^[:space:]] && "$t" != *$'\t'* ]] ||
      { echo "proof-map malformed row: $line"; return 1; }
    count=$((count + 1))
    if ! out=$(cargo test --locked --lib -- --exact "$t" 2>&1); then
      echo "rust test missing/failed: $t"; printf '%s\n' "$out"; return 1
    fi
    grep -Eq '^test result: ok\. 1 passed; 0 failed;' <<< "$out" ||
      { echo "rust test missing/failed: $t"; printf '%s\n' "$out"; return 1; }
    echo "ok $th -> $t"
  done < "$1"
  [ "$count" -gt 0 ] || { echo "proof-map has no test rows"; return 1; }
}
witness_check() {
  local res="$1"; shift
  awk -F'\t' -v expected="$*" '
    BEGIN {n=split(expected, ids, " ")}
    NR==1 {if ($0 != "id\tstep\texpect\texit\treason_check\tverdict") bad=1; next}
    {seen[$1]++; if (NF!=6 || $6!="PASS") bad=1; rows++}
    END {
      for (i=1;i<=n;i++) if (seen[ids[i]]!=1) {print "witness missing gate: " ids[i]; bad=1}
      if (!rows) {print "witness has no gate rows"; bad=1}
      for (id in seen) if (seen[id]!=1) bad=1
      exit bad
    }' "$res"
}
seal_evidence() {
  local dir="$1"; shift
  ( cd "$dir" && sha256sum ./*.log env.txt results.tsv summary.txt lean-theorems.txt > SHA256SUMS ) ||
    { echo "witness checksum failed"; return 1; }
  witness_check "$dir/results.tsv" "$@"
}

# --- S0: skeleton builds with the locked graph ---
run S0a build pass - "$ROOT" cargo build --locked --all-targets
# --- S1: quality ---
run S1a fmt pass - "$ROOT" cargo fmt --all -- --check
run S1b clippy pass - "$ROOT" cargo clippy --locked --all-targets -- -D warnings
run S1c test-coverage pass - "$ROOT" cargo llvm-cov nextest --locked --fail-under-lines 80
# --- S2: supply chain ---
run S2a deny pass - "$ROOT" cargo deny --locked check
run S2b audit pass - "$ROOT" cargo audit

# --- A8: gate self-test. Each gate must FAIL on a known-bad input, for the RIGHT reason ---
CAN="$WORK/canaries"; mkdir -p "$CAN"
mk() { mkdir -p "$CAN/$1"; cp -r "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/src" "$ROOT/deny.toml" "$CAN/$1/"; }
mk fmt;    printf 'pub fn   ugly( ) {}\n' >> "$CAN/fmt/src/lib.rs"
CARGO_TARGET_DIR="$CAN/fmt/target" run C1 canary-fmt fail 'Diff in' "$CAN/fmt" cargo fmt --all -- --check
mk clippy; printf '\npub fn is_empty_vec(v: &[u32]) -> bool { v.len() == 0 }\n' >> "$CAN/clippy/src/lib.rs"
CARGO_TARGET_DIR="$CAN/clippy/target" run C2 canary-clippy fail 'len_zero' "$CAN/clippy" cargo clippy --all-targets -- -D warnings
mk test;   printf '\n#[test]\nfn canary_fails() { assert_eq!(1 + 1, 3); }\n' >> "$CAN/test/src/lib.rs"
CARGO_TARGET_DIR="$CAN/test/target" run C3 canary-test fail 'canary_fails' "$CAN/test" cargo nextest run
mk deny;   sed -i 's/^license = .*/license = "GPL-3.0-only"/' "$CAN/deny/Cargo.toml"
grep -q '^license = ' "$CAN/deny/Cargo.toml" || sed -i '/^\[package\]/a license = "GPL-3.0-only"' "$CAN/deny/Cargo.toml"
CARGO_TARGET_DIR="$CAN/deny/target" run C4 canary-deny-license fail 'GPL-3.0' "$CAN/deny" cargo deny check licenses

# --- L: Lean stage. Mandatory unless REQUIRE_LEAN=0 AND no Lean project exists (then visibly SKIPPED). ---
export PY="${PY:-python3}"
echo "require_lean=${REQUIRE_LEAN:-1} | python: $(command -v "$PY" >/dev/null && "$PY" --version 2>&1 | head -1 || echo none)" >> "$EV/env.txt"
if ! LMODE="$(lean_mode "$ROOT")"; then printf '%s\n' "$LMODE" >&2; exit 1; fi
# Self-tests of the mode switch and Python check (run in both modes)
mkdir -p "$CAN/mode/two/a" "$CAN/mode/two/b" "$CAN/mode/none"
touch "$CAN/mode/two/a/lakefile.toml" "$CAN/mode/two/b/lakefile.toml"
run CL29 canary-skip-not-allowed-with-projects fail '^LEAN multiple projects' "$ROOT" env REQUIRE_LEAN=0 bash -c "$(declare -f lean_project lean_mode); lean_mode \"\$1\"" _ "$CAN/mode/two"
run CL30 canary-require-lean-invalid-value fail '^REQUIRE_LEAN must be 0 or 1' "$ROOT" env REQUIRE_LEAN=yes bash -c "$(declare -f lean_project lean_mode); lean_mode \"\$1\"" _ "$CAN/mode/none"
run CL32 canary-missing-lean-required fail '^LEAN project missing' "$ROOT" env REQUIRE_LEAN=1 bash -c "$(declare -f lean_project lean_mode); lean_mode \"\$1\"" _ "$CAN/mode/none"
if [ "$LMODE" = skip ]; then
  run LSKIP lean-stage-skipped pass - "$ROOT" bash -c 'echo "LEAN stage SKIPPED: no lakefile.toml and REQUIRE_LEAN=0"'
  : > "$EV/lean-theorems.txt"
else
LF="$(lean_project "$ROOT")"
run L00 python-for-lean-config pass - "$ROOT" py_check
# CL31 needs a Python interpreter, so it runs only when the Lean stage runs (Rust-only skip needs no Python)
run CL31 canary-python-too-old fail '^PYTHON too old' "$ROOT" env PY_MIN=99.0 bash -c "$(declare -f py_check); py_check"
{
  LSRC="$(cd "$(dirname "$LF")" && pwd)"
  echo "lean_dir=${LSRC#"$ROOT"/}" >> "$EV/env.txt"
  # L0: toolchain must be pinned in-repo (lean-toolchain), else builds are not reproducible
  if [ -f "$LSRC/lean-toolchain" ]; then LTC="$(cat "$LSRC/lean-toolchain")"; else LTC=""; fi
  run L0 lean-toolchain-pinned pass - "$ROOT" bash -c '[[ "$1" =~ ^leanprover/lean4:v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "LEAN pin missing/invalid"; exit 1; }' _ "$LTC"
  # LEAN_TOOLCHAIN (optional) = name of a pre-installed, digest-verified toolchain to RUN with;
  # the in-repo lean-toolchain stays the source of truth and L0b checks the versions agree.
  LTC_RUN="${LEAN_TOOLCHAIN:-$LTC}"
  LX=(elan run "$LTC_RUN")
  echo "lean: pinned=${LTC:-NONE} | run_with=${LTC_RUN:-NONE}" >> "$EV/env.txt"
  run L0b lean-version-matches-pin pass - "$ROOT" lean_version "$LTC"
  LW="$WORK/lean"; mkdir -p "$LW"; cp -r "$LSRC/." "$LW/"; rm -rf "$LW/.lake"
  run L1 lake-build pass - "$LW" lean_build "$LW"
  # L2: axiom audit computed by Lean itself over every user theorem of the project's
  # lean_lib modules (attributes, namespaces included); Lean errors propagate; sorryAx = FAIL.
  lean_audit() { local d="$1" mods m audit
    mods="$(lean_modules "$d")" || return 2
    [ -n "$mods" ] || { echo "audit: no lean_lib in lakefile.toml"; return 2; }
    audit="$(mktemp "$d/ZzAuditXXXXXX.lean")" || return 2
    { echo "import Lean"; for m in $mods; do echo "import $m"; done
      echo 'open Lean Elab Command'
      echo 'elab "#audit_axioms" : command => do'
      echo '  let env ← getEnv'
      printf '  let mods : Array Name := #[%s]\n' "$(for m in $mods; do printf '`%s, ' "$m"; done | sed 's/, $//')"
      cat <<'LEAN'
  -- lean_lib roots AND their submodules (Root.Sub...), so imported project files are audited too
  let inProject (m : Name) : Bool := mods.any (fun r => r == m || r.isPrefixOf m)
  if (mods.filterMap env.getModuleIdx?).size != mods.size then throwError "AUDIT module not found"
  let mut bad : Array Name := #[]
  let mut n : Nat := 0
  for (name, ci) in env.constants.map₁.toList do
    let some mi := env.getModuleIdxFor? name | continue
    unless inProject (env.header.moduleNames[mi.toNat]!) do continue
    let .thmInfo _ := ci | continue
    n := n + 1
    let axs ← liftCoreM (collectAxioms name)
    logInfo m!"AUDIT checked {name} axioms {axs}"
    -- Audit auxiliaries too, but only declarations need their own proof-map rows.
    let userName := (privateToUserName? name).getD name
    -- Constructor auxiliaries generated by Lean for every structure/inductive (C.mk.inj, C.mk.injEq,
    -- C.mk.sizeOf_spec) are axiom-checked above but are not user theorems: no proof-map row required.
    -- Exemption is limited to the exact generated names; a user theorem such as C.mk.foo still needs a row
    -- (a user cannot declare C.mk.inj etc. themselves: those names are taken by the generated ones).
    let genSuffix := match name with
      | .str _ s => s == "inj" || s == "injEq" || s == "sizeOf_spec"
      | _ => false
    let ctorAux := genSuffix && match env.find? name.getPrefix with
      | some (.ctorInfo _) => true
      | _ => false
    -- Lean generates protected brecOn.eq equation theorems for recursive inductives.
    -- The exact protected name plus auxiliary-recursor metadata distinguishes these from user theorems.
    let recursorAux := match name with
      | .str parent "eq" => match parent with
        | .str _ "brecOn" => isProtected env name && isBRecOnRecursor env parent
        | _ => false
      | _ => false
    unless userName.isInternal || ctorAux || recursorAux do logInfo m!"AUDIT theorem {name} axioms {axs}"
    if axs.contains ``sorryAx then bad := bad.push name
  logInfo m!"AUDIT theorems={n}"
  if n == 0 then throwError "AUDIT found no theorems"
  unless bad.isEmpty do throwError m!"AUDIT sorryAx in {bad}"
#audit_axioms
LEAN
    } > "$audit" || return 2
    ( cd "$d" && { lean_build "$d" || { echo "AUDIT build failed"; exit 3; }; } && "${LX[@]}" lake env lean "$audit" ) > "$d/axioms.out" 2>&1
    local rc=$?
    rm "$audit" || return 2
    cat "$d/axioms.out"; return "$rc"; }
  AUDIT="$(declare -f lean_audit lean_modules lean_build); $(declare -p LX)"
  run L2 lean-axiom-audit pass - "$LW" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$LW"
  grep -oE '^AUDIT theorem [^ ]+' "$LW/axioms.out" | awk '{print $3}' | sort -u > "$EV/lean-theorems.txt"
  run L3 lean-no-sorry-text pass - "$LW" bash -c "$(declare -f lean_text); lean_text '$LW'"
  # Rust<->Lean traceability: proof-map.tsv lines "lean_theorem<TAB>rust_test_path"
  # proof-map check: each theorem needs a row whose Rust-test column is non-empty
  pm_check() { local th="$1" pm="$2" rc=0 t count=0
    [[ -f "$pm" && -r "$pm" ]] || { echo "proof-map missing: $pm"; return 1; }
    [[ -f "$th" && -r "$th" ]] || { echo "theorem inventory missing: $th"; return 1; }
    while read -r t || [ -n "$t" ]; do [ -z "$t" ] && continue
      count=$((count + 1))
      awk -F'\t' -v t="$t" 'NF==2 && $1==t && $2 ~ /[^[:space:]]/ {f=1} END{exit !f}' "$pm" || { echo "unmapped theorem: $t"; rc=1; }
    done < "$th"
    [ "$count" -gt 0 ] || { echo "theorem inventory empty"; return 1; }
    return "$rc"; }
  # X1/X2 are mandatory whenever the Lean stage runs: a missing proof-map.tsv is a FAIL, not a skip.
  run X1 proof-map-covers-theorems pass - "$ROOT" bash -c "$(declare -f pm_check); pm_check '$EV/lean-theorems.txt' proof-map.tsv"
  run X2 proof-map-rust-tests-pass pass - "$ROOT" bash -c "$(declare -f pm_tests); pm_tests proof-map.tsv"
  # Lean canaries: gates must FAIL for the right reason.
  # Reason regexes must not match the echoed command line itself (run() logs "$ cmd").
  mkL() { mkdir -p "$CAN/$1"; cp -r "$LSRC/." "$CAN/$1/"; rm -rf "$CAN/$1/.lake"; }
  MODULES="$(lean_modules "$LSRC" paths)"
  FIRST_MODULE="${MODULES%%$'\n'*}"
  ROOTMOD="${FIRST_MODULE%%$'\t'*}"
  ROOTFILE="${FIRST_MODULE#*$'\t'}"
  mkL lsorry; printf '\ntheorem canary_bad : False := by sorry\n' >> "$CAN/lsorry/$ROOTFILE"
  run CL1 canary-lean-sorry fail "AUDIT sorryAx in \\[canary_bad" "$CAN/lsorry" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$CAN/lsorry"
  mkL lwrong; printf '\ntheorem canary_wrong : (1 : Nat) = 2 := by rfl\n' >> "$CAN/lwrong/$ROOTFILE"
  run CL2 canary-lean-false-proof fail 'canary_wrong|rfl. failed' "$CAN/lwrong" "${LX[@]}" lake build
  # CL3: an annotated theorem missing from proof-map.tsv must be reported (discovery covers @[attr])
  mkL lunmap; printf '\n@[simp] theorem canary_unmapped : (2 : Nat) + 2 = 4 := rfl\n' >> "$CAN/lunmap/$ROOTFILE"
  run CL3 canary-unmapped-annotated-theorem fail '^unmapped theorem: canary_unmapped' "$CAN/lunmap" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/lunmap" "$ROOT/proof-map.tsv"
  # CL5: a theorem in an imported project submodule must be discovered (X1 must report it)
  mkL lsub
  mkdir -p "$CAN/lsub/${ROOTFILE%.lean}"; printf 'theorem canary_submodule : True := trivial\n' > "$CAN/lsub/${ROOTFILE%.lean}/CanarySub.lean"
  sed -i "1i import $ROOTMOD.CanarySub" "$CAN/lsub/$ROOTFILE"
  run CL5 canary-submodule-theorem-discovered fail '^unmapped theorem: canary_submodule' "$CAN/lsub" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/lsub" "$ROOT/proof-map.tsv"
  # CL6: a proof-map row with an empty Rust-test column must not satisfy X1
  mkdir -p "$CAN/pmempty"; awk -F'\t' 'BEGIN{OFS="\t"} /^#/||!NF{print;next} !d{$2="";d=1} {print}' "$ROOT/proof-map.tsv" > "$CAN/pmempty/proof-map.tsv"
  run CL6 canary-empty-rust-column fail '^unmapped theorem: ' "$CAN/pmempty" bash -c "$(declare -f pm_check); pm_check '$EV/lean-theorems.txt' proof-map.tsv"
  # CL7: with no proof-map.tsv at all, X1 must fail (no silent skip)
  mkdir -p "$CAN/pmmissing"
  run CL7 canary-missing-proof-map fail '^proof-map missing' "$CAN/pmmissing" bash -c "$(declare -f pm_check); pm_check '$EV/lean-theorems.txt' proof-map.tsv"
  # CL4: a Lean error inside the audit itself must fail L2 (no silent pass)
  mkL lbroken; printf '\nnamespace Broken\ntheorem canary_broken : True := by exact (rfl : 1 = 2)\nend Broken\n' >> "$CAN/lbroken/$ROOTFILE"
  run CL4 canary-audit-propagates-lean-error fail '^AUDIT build failed' "$CAN/lbroken" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$CAN/lbroken"

  # Audit regressions: missing inputs, empty loops, hidden statuses and evidence.
  mkdir -p "$CAN/discovery" "$CAN/text/Sub" "$CAN/maps" "$CAN/witness"
  run CL8 canary-missing-lean-project fail '^LEAN project missing' "$ROOT" lean_project "$CAN/discovery"
  mkdir -p "$CAN/discovery/a" "$CAN/discovery/b"
  cp -r "$LSRC/." "$CAN/discovery/a/"
  cp -r "$LSRC/." "$CAN/discovery/b/"
  run CL9 canary-multiple-lean-projects fail '^LEAN multiple projects' "$ROOT" lean_project "$CAN/discovery"
  mkdir -p "$CAN/nested-fixtures/a" "$CAN/nested-fixtures/x/fixtures"
  cp -r "$LSRC/." "$CAN/nested-fixtures/a/"
  cp -r "$LSRC/." "$CAN/nested-fixtures/x/fixtures/"
  run CL36 canary-nested-fixtures-project-discovered fail '^LEAN multiple projects' "$ROOT" lean_project "$CAN/nested-fixtures"
  run CL10 canary-missing-lean-sources fail '^LEAN sources missing' "$ROOT" lean_text "$CAN/text"
  printf '%s\n' '-- clean root' > "$CAN/text/Root.lean"
  printf '%s\n' '-- sorry in a nested source' > "$CAN/text/Sub/Nested.lean"
  run CL11 canary-nested-sorry-text fail '^LEAN forbidden proof text' "$ROOT" lean_text "$CAN/text"
  printf 'mapped\n' > "$CAN/maps/theorems"
  printf 'mapped\ttests::adds\n' > "$CAN/maps/valid.tsv"
  : > "$CAN/maps/empty"
  run CL12 canary-missing-theorem-list fail '^theorem inventory missing' "$ROOT" pm_check "$CAN/maps/missing" "$CAN/maps/valid.tsv"
  run CL13 canary-empty-theorem-list fail '^theorem inventory empty' "$ROOT" pm_check "$CAN/maps/empty" "$CAN/maps/valid.tsv"
  printf 'unmapped_final_line' > "$CAN/maps/no-newline"
  run CL14 canary-unterminated-theorem fail '^unmapped theorem: unmapped_final_line' "$ROOT" pm_check "$CAN/maps/no-newline" "$CAN/maps/valid.tsv"
  printf '# comment-only map\n' > "$CAN/maps/comments.tsv"
  run CL15 canary-empty-proof-map fail '^proof-map has no test rows' "$ROOT" bash -c "$(declare -f pm_tests); pm_tests '$CAN/maps/comments.tsv'"
  # Shell functions stand in for Cargo only in these status/output regression fixtures.
  cargo() { printf 'fixture text: 1 passed\n\ntest result: ok. 0 passed; 0 failed;\n'; }
  run CL16 canary-test-output-is-not-summary fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  cargo() { printf 'test result: ok. 1 passed; 0 failed; 0 ignored;\n'; return 1; }
  run CL17 canary-cargo-status fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  cargo() { printf 'test result: ok. 11 passed; 0 failed; 0 ignored;\n'; }
  run CL18 canary-exact-test-count fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  unset -f cargo
  run CL19 canary-command-is-not-output fail '^reason absent from tool output' "$ROOT" bash -c "
    $(declare -f run)
    EV='$CAN/witness'; RES='$CAN/witness/inner.tsv'; WORK='$CAN/witness'
    run inner command-reason fail COMMAND_ONLY_REASON '$ROOT' bash -c 'exit 1' COMMAND_ONLY_REASON
    if grep -q FAIL_WRONG_REASON \"\$RES\"; then echo 'reason absent from tool output'; exit 1; fi"
  printf 'id\tstep\texpect\texit\treason_check\tverdict\n' > "$CAN/witness/results.tsv"
  run CL20 canary-missing-witness-row fail '^witness missing gate: L2' "$ROOT" witness_check "$CAN/witness/results.tsv" L2
  run CL21 canary-checksum-failure fail '^witness checksum failed' "$ROOT" seal_evidence "$CAN/witness"
  mkL lroots
  # project-independent: derive the library name instead of assuming the template's "CheckedAdd"
  sed -i "/^name = \"$ROOTMOD\"/a roots = [\"$ROOTMOD\", \"Other\"]" "$CAN/lroots/lakefile.toml"
  grep -q '^roots = ' "$CAN/lroots/lakefile.toml" || { echo "canary setup failed: lean_lib \"$ROOTMOD\" not found" >&2; exit 1; }
  printf 'theorem canary_custom_root : True := trivial\n' > "$CAN/lroots/$(dirname "$ROOTFILE")/Other.lean"
  run CL22 canary-custom-library-root fail '^unmapped theorem: canary_custom_root' "$CAN/lroots" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/lroots" "$ROOT/proof-map.tsv"
  mkL lorphan
  mkdir -p "$CAN/lorphan/$(dirname "$ROOTFILE")/$ROOTMOD"
  printf 'theorem canary_orphan : False := by sorry\n' > "$CAN/lorphan/$(dirname "$ROOTFILE")/$ROOTMOD/Orphan.lean"
  run CL23 canary-unimported-submodule fail 'AUDIT sorryAx in .*canary_orphan' "$CAN/lorphan" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$CAN/lorphan"
  mkL ltoml
  printf '\n[[ lean_lib ]]\nname = "Extra"\n' >> "$CAN/ltoml/lakefile.toml"
  printf 'theorem canary_extra_library : True := trivial\n' > "$CAN/ltoml/$(dirname "$ROOTFILE")/Extra.lean"
  run CL24 canary-toml-library-discovery fail '^unmapped theorem: canary_extra_library' "$CAN/ltoml" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/ltoml" "$ROOT/proof-map.tsv"
  elan() { printf 'Lean (version 4.35.0, fixture)\n'; return 1; }
  run CL25 canary-version-command-status fail '^LEAN version command failed' "$ROOT" lean_version 'leanprover/lean4:v4.35.0'
  unset -f elan
  mkL lprivate
  printf '\nprivate theorem canary_private : False := by sorry\n' >> "$CAN/lprivate/$ROOTFILE"
  run CL26 canary-private-theorem fail 'AUDIT sorryAx in .*canary_private' "$CAN/lprivate" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$CAN/lprivate"
  mkL lgenerated
  sed -i '1i import Lean' "$CAN/lgenerated/$ROOTFILE"
  cat >> "$CAN/lgenerated/$ROOTFILE" <<'LEAN'

open Lean Elab Command in
run_elab addDecl (.thmDecl {
  name := `canary_generated
  levelParams := []
  type := mkConst ``True
  value := mkConst ``True.intro
})
LEAN
  run CL27 canary-theorem-without-source-range fail '^unmapped theorem: canary_generated' "$CAN/lgenerated" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/lgenerated" "$ROOT/proof-map.tsv"
  mkL lnodefault
  sed -i 's/^defaultTargets = .*/defaultTargets = []/' "$CAN/lnodefault/lakefile.toml"
  printf '\ntheorem canary_no_default : (1 : Nat) = 2 := by rfl\n' >> "$CAN/lnodefault/$ROOTFILE"
  run CL28 canary-empty-default-targets fail 'rfl. failed' "$CAN/lnodefault" lean_build "$CAN/lnodefault"
  # CL33 (positive control): a structure's constructor auxiliaries are axiom-checked but need no proof-map row
  mkL lstruct
  printf '\nstructure CanaryS where\n  x : Nat\n' >> "$CAN/lstruct/$ROOTFILE"
  run CL33 canary-structure-auxiliaries-not-required pass - "$CAN/lstruct" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -q '^AUDIT checked CanaryS.mk.inj ' axioms.out || { echo 'constructor auxiliary not axiom-checked'; exit 1; }; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/lstruct" "$ROOT/proof-map.tsv"
  # CL34: a USER theorem in a constructor namespace must still require a proof-map row
  mkL luserctor
  printf '\nstructure CanaryS where\n  x : Nat\ntheorem CanaryS.mk.user_property : True := trivial\n' >> "$CAN/luserctor/$ROOTFILE"
  run CL34 canary-user-theorem-in-ctor-namespace fail '^unmapped theorem: CanaryS.mk.user_property' "$CAN/luserctor" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; pm_check th.txt \"\$2\"" _ "$CAN/luserctor" "$ROOT/proof-map.tsv"
  # CL35: mutual recursor equations are axiom-checked but are not user theorems to map
  mkL lmutual
  cat >> "$CAN/lmutual/$ROOTFILE" <<'LEAN'

mutual
  inductive CanaryTree where
    | leaf : Nat → CanaryTree
    | branch : CanaryForest → CanaryTree

  inductive CanaryForest where
    | nil : CanaryForest
    | cons : CanaryTree → CanaryForest → CanaryForest
end

theorem CanaryTree.brecOn.user_property : True := trivial
LEAN
  run CL35 canary-mutual-recursion-auxiliaries pass - "$CAN/lmutual" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; for n in CanaryTree CanaryForest; do grep -q \"^AUDIT checked \$n.brecOn.eq \" axioms.out || { echo \"mutual recursor auxiliary not axiom-checked: \$n\"; exit 1; }; if grep -q \"^AUDIT theorem \$n.brecOn.eq \" axioms.out; then echo \"mutual recursor auxiliary incorrectly requires proof-map row: \$n\"; exit 1; fi; done; grep -q '^AUDIT theorem CanaryTree.brecOn.user_property ' axioms.out || { echo 'user theorem in recursor namespace not inventoried'; exit 1; }; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; if pm_check th.txt \"\$2\" > missing.out 2>&1; then echo 'user theorem incorrectly exempted from proof-map'; exit 1; fi; grep -qx 'unmapped theorem: CanaryTree.brecOn.user_property' missing.out || { cat missing.out; exit 1; }; cp \"\$2\" proof-map.tsv; printf 'CanaryTree.brecOn.user_property\\ttests::adds\\n' >> proof-map.tsv; pm_check th.txt proof-map.tsv" _ "$CAN/lmutual" "$ROOT/proof-map.tsv"
}
fi

# --- summary ---
TOTAL=$(($(wc -l < "$RES") - 1)); OK=$(grep -c $'\tPASS$' "$RES" || true)
echo "PROGRESS=$OK/$TOTAL" | tee "$EV/summary.txt"
echo "evidence=$EV" | tee -a "$EV/summary.txt"
echo "build_dir=$WORK (outside repo, temporary)" | tee -a "$EV/summary.txt"
if [ "$LMODE" = skip ]; then
  seal_evidence "$EV" S0a S1a S1b S1c S2a S2b C{1..4} CL29 CL30 CL32 LSKIP
else
  seal_evidence "$EV" S0a S1a S1b S1c S2a S2b C{1..4} CL{29..32} L00 L0 L0b L1 L2 L3 X1 X2 CL{1..28} CL{33..36}
fi
