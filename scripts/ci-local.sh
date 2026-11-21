#!/usr/bin/env bash
# Minimal Rust CI core, steps S0-S2 + gate self-test (canaries).
# Every step writes a log; results.tsv is the witness table. NO_WITNESS -> NO_CLOSE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# helper scripts live next to this file; resolve BEFORE any cd (a relative $0/BASH_SOURCE breaks afterwards)
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EV="$ROOT/evidence/$STAMP"
mkdir -p "$ROOT/evidence"
# CI uploads exactly THIS run's directory (the repo also tracks older evidence dirs)
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "evidence-dir=$EV" >> "$GITHUB_OUTPUT"; fi
mkdir "$EV" || { echo "witness directory unavailable: $EV" >&2; exit 1; }
RES="$EV/results.tsv"
printf 'id\tstep\texpect\texit\treason_check\tverdict\n' > "$RES"
: > "$EV/signatures.tsv"
export CARGO_TERM_COLOR=never
# Build outputs live OUTSIDE the repo/evidence folder: evidence holds only logs,
# and the run does not depend on being allowed to delete files in the project folder.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rust-cicd-core.XXXXXX")"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORK/target}"
# Code under test (build.rs, proc macros, tests, Lean elaboration) runs jailed: it cannot write the
# evidence, the scripts, .git, cargo config or the runner's command files (threat CI-9, gates S0s/C28/C29).
# shellcheck source=sandbox.sh
. "$SD/sandbox.sh"; export SANDBOX_WORK="$WORK"; sandbox_enable
# HOST: trusted scratch under WORK that is never a jail work dir. Files the host writes or must not have
# swapped (audit scripts, audit output) live here, not in a directory jailed code could write.
HOST="$WORK/host"; mkdir "$HOST"
export PY="${PY:-python3}"   # used by S1f/S1g before the Lean stage too

# --- toolchain selection BEFORE any rustc/cargo call (#45 item 8) ---
# rustup picks the toolchain from rust-toolchain(.toml) in the cwd and its parents: a checkout file with
# `path = "/abs/dir"` (or a legacy rust-toolchain file naming a directory) makes the first UNJAILED rustc/cargo
# call run a checkout-supplied binary - and it can print the pinned version. RUSTUP_TOOLCHAIN beats every
# such file, so it is set here from the validated pin (CI sets it in the workflow; S0b checks the two agree).
toolchain_check() { # <root> [channel]: every toolchain file under <root> (and the pin's parents) is plain;
  # with "channel" print the pin's exact version (the first rust-toolchain.toml from <root> upwards)
  "$PY" - "$1" "${2:-}" <<'PY'
import os, re, sys
root, want = os.path.realpath(sys.argv[1]), sys.argv[2]
try:
    import tomllib
except ImportError:
    sys.exit("RUST cannot validate toolchain files: python without tomllib (3.11+)")
files, pin, bad = [], None, []
for d, dirs, names in os.walk(root):
    dirs[:] = [x for x in dirs if x not in (".git", "target", "evidence", ".lake")]
    files += [os.path.join(d, n) for n in names if n in ("rust-toolchain", "rust-toolchain.toml")]
d = root
while True:
    for n in ("rust-toolchain", "rust-toolchain.toml"):
        f = os.path.join(d, n)
        if os.path.isfile(f) and f not in files: files.append(f)
    if pin is None and os.path.isfile(os.path.join(d, "rust-toolchain.toml")): pin = os.path.join(d, "rust-toolchain.toml")
    if d == "/": break
    d = os.path.dirname(d)
for f in sorted(files):
    if os.path.basename(f) == "rust-toolchain":
        bad.append(f"RUST legacy toolchain file not allowed (it can name a directory): {f}"); continue
    try:
        t = tomllib.load(open(f, "rb"))
    except Exception as e:
        bad.append(f"RUST toolchain file {f}: unreadable ({e})"); continue
    extra = set(t) - {"toolchain"}
    keys = set(t.get("toolchain", {})) - {"channel", "components", "profile", "targets"}
    for k in sorted(extra | keys):
        bad.append(f"RUST toolchain file {f}: forbidden key {k}")
if bad: sys.exit("\n".join(bad))
if want == "channel":
    if pin is None: sys.exit(f"RUST toolchain not pinned: no rust-toolchain.toml from {root} upwards")
    c = tomllib.load(open(pin, "rb")).get("toolchain", {}).get("channel", "")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(c)): sys.exit(f"RUST toolchain pin must be an exact x.y.z version: {pin}")
    print(c)
else:
    print(f"RUST toolchain files plain ({len(files)})")
PY
}
if [ -z "${RUSTUP_TOOLCHAIN:-}" ]; then
  # an invalid pin selects no toolchain at all (every rust call fails, S0b names the reason) - never the file's
  RUSTUP_TOOLCHAIN="$(toolchain_check "$ROOT" channel 2>/dev/null)" || RUSTUP_TOOLCHAIN=invalid-rust-pin
fi
export RUSTUP_TOOLCHAIN

# --- environment witness ---
# No "| head" here: under pipefail a closed pipe (SIGPIPE) would abort the whole run before any gate (found 2026-11-17).
{
  echo "utc=$STAMP"; uname -a
  for t in cargo rustc cargo-clippy rustfmt cargo-nextest cargo-llvm-cov cargo-deny cargo-audit cargo-mutants cargo-vet; do
    p="$(command -v "$t" || true)"
    if [ -z "$p" ]; then echo "$t: MISSING"; continue; fi
    # rustup installs identical proxy shims; hash the real toolchain binary instead
    real="$p"; command -v rustup >/dev/null && real="$(rustup which "$t" 2>/dev/null || echo "$p")"
    case "$t" in cargo-*) ver="$(cargo "${t#cargo-}" --version 2>&1 | sed -n 1p)";; *) ver="$("$t" --version 2>&1 | sed -n 1p)";; esac
    echo "$t: $ver | sha256=$(sha256sum "$real" | cut -c1-64)"
  done
  echo "git_head=$(git rev-parse HEAD 2>/dev/null || echo none)"
  echo "cargo_lock_sha256=$(sha256sum Cargo.lock 2>/dev/null | cut -c1-64)"
} > "$EV/env.txt" 2>&1

# run <id> <name> <expect:pass|fail> <reason-regex-or-dash> <workdir> <cmd...>
# Check signature of a step (#45 item 4): its command with run-specific paths (under ROOT/WORK/EV), bare numbers and
# --locked normalised, one short hash per word. A canary named as the breaker of an assumption must start with the
# signature of its guard gate - it exercises the same check, not just any check (claim-verdict.sh).
sig_of() {
  local a out=() r
  for a in "$@"; do
    [ "$a" = --locked ] && continue
    for r in "$EV" "$WORK" "$ROOT"; do [ -n "$r" ] && a="${a//$r/<path>}"; done
    # the rest of such a path names the run's own copy (canaries/fork-env, mutants-c5, ...): one token for all
    a="$(sed -E "s#<path>[^[:space:]'\";)]*#<path>#g" <<< "$a")"
    [[ "$a" =~ ^[0-9]+$ ]] && a="<n>"
    out+=("$(printf '%s' "$a" | sha256sum | cut -c1-12)")
  done
  printf '%s' "${out[*]}"
}
run() {
  local id="$1" name="$2" expect="$3" rx="$4" wd="$5"; shift 5
  printf '%s\t%s\n' "$id" "$(sig_of "$@")" >> "$EV/signatures.tsv"
  local log="$EV/$id-$name.log" output="$WORK/$id.output" code
  if [ -z "${JAIL_MOCK:-}" ] && declare -F jail_armed >/dev/null && ! jail_armed; then
    echo "JAIL disarmed before $id: cargo/elan are not the sandbox wrappers" > "$output"; code=126
  elif ( cd "$wd" && "$@" ) > "$output" 2>&1; then code=0; else code=$?; fi
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
    BEGIN {n=split(expected, ids, " "); for (i=1;i<=n;i++) want[ids[i]]=1}
    NR==1 {if ($0 != "id\tstep\texpect\texit\treason_check\tverdict") bad=1; next}
    {seen[$1]++; if (NF!=6 || $6!="PASS") bad=1; rows++}
    END {
      for (i=1;i<=n;i++) if (seen[ids[i]]!=1) {print "witness missing gate: " ids[i]; bad=1}
      if (!rows) {print "witness has no gate rows"; bad=1}
      for (id in seen) { if (seen[id]!=1) bad=1; if (!(id in want)) {print "witness unlisted gate: " id; bad=1} }
      exit bad
    }' "$res"
}
seal_evidence() {
  local dir="$1"; shift
  rm -f "$dir/SHA256SUMS" ||
    { echo "witness checksum failed"; return 1; }
  printf '%s\n' "$@" > "$dir/expected-gates.txt" ||
    { echo "witness gate inventory failed"; return 1; }
  witness_check "$dir/results.tsv" "$@" || return 1
  ( cd "$dir" && sha256sum ./*.log env.txt expected-gates.txt results.tsv signatures.tsv summary.txt lean-theorems.txt > SHA256SUMS ) ||
    { echo "witness checksum failed"; return 1; }
}

# --- S0b: the Rust toolchain is pinned in-repo and the running rustc matches it ---
rust_pin() { # <rust-toolchain.toml> <rustc --version output>
  local f="$1" have="$2" want
  [ -f "$f" ] || { echo "RUST toolchain not pinned: $f missing"; return 1; }
  want="$(sed -n 's/^channel *= *"\([0-9][0-9.]*\)".*/\1/p' "$f")"
  [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "RUST toolchain pin must be an exact x.y.z version: $f"; return 1; }
  [[ "$have" == "rustc $want "* ]] || { echo "RUST toolchain mismatch: pinned $want, running ${have:-none}"; return 1; }
  echo "rust ok: $want"
}
rust_pin_strict() { toolchain_check "$ROOT" && rust_pin "$@"; }   # S0b: plain toolchain files AND the pin runs
RUSTC_VERSION="$(rustc --version 2>&1 || true)"
# rustup resolves rust-toolchain.toml from the project dir upwards; do the same (fixtures inherit the root pin)
PIN_DIR="$ROOT"; while [ "$PIN_DIR" != / ] && [ ! -f "$PIN_DIR/rust-toolchain.toml" ]; do PIN_DIR="$(dirname "$PIN_DIR")"; done
echo "rust_pin_file=$PIN_DIR/rust-toolchain.toml | RUSTUP_TOOLCHAIN=$RUSTUP_TOOLCHAIN | $RUSTC_VERSION" >> "$EV/env.txt"
run S0b rust-toolchain-pinned pass - "$ROOT" rust_pin_strict "${PIN_DIR%/}/rust-toolchain.toml" "$RUSTC_VERSION"
# S0s: the jail must actually start (no bubblewrap / no user namespaces -> every jailed gate would fail anyway)
run S0s sandbox-active pass - "$ROOT" sandbox bash -c 'echo "SANDBOX active"'
# S0f: dependencies are downloaded BEFORE any jailed step (the jail has no network); fetch runs no project code
run S0f fetch-dependencies pass - "$ROOT" cargo fetch --locked
# --- S0: skeleton builds with the locked graph ---
run S0a build pass - "$ROOT" cargo build --locked --all-targets
# --- S1: quality ---
run S1a fmt pass - "$ROOT" cargo fmt --all -- --check
run S1b clippy pass - "$ROOT" cargo clippy --locked --all-targets -- -D warnings
# S1e: no panicking construct in non-test code (lib + bins; cargo's default targets exclude tests).
# A panic in shipped code is a denial of service; a local #[allow(...)] stays visible in review.
NOPANIC=(-F clippy::indexing_slicing -F clippy::string_slice -F clippy::arithmetic_side_effects
  -F clippy::unwrap_used -F clippy::expect_used -F clippy::panic -F clippy::unreachable
  -F clippy::todo -F clippy::unimplemented -F clippy::panic_in_result_fn)
run S1e no-panic-lints pass - "$ROOT" cargo clippy --locked -- -D warnings "${NOPANIC[@]}"
# S1f/S1g: judge the program that ships (threat CODE-2). Every other gate judges a variant: tests run in the
# dev profile with cfg(test) and the env cargo sets, clippy under cfg(clippy), Kani under cfg(kani), fuzzing under
# cfg(fuzzing). A fork on any of these lets the judged variant be correct and the shipped one wrong.
# S1f (behaviour): the test binaries, built in RELEASE, run directly under `env -i` (no CARGO_* runtime variables).
release_tests() { # <crate dir>
  local exes n=0 e
  exes="$(cd "$1" && cargo test --release --locked --no-run --message-format=json 2>/dev/null | "$PY" -c '
import json, sys
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("reason") == "compiler-artifact" and (m.get("profile") or {}).get("test") and m.get("executable"):
        print(m["executable"])')" || { echo "RELEASE-TESTS build failed"; return 1; }
  [ -n "$exes" ] || { echo "RELEASE-TESTS no test binary built"; return 1; }
  while IFS= read -r e; do
    n=$((n + 1)); echo "RELEASE-TESTS run $(basename "$e")"
    ( cd "$1" && sandbox env -i PATH=/usr/bin:/bin "$e" -q ) || { echo "RELEASE-TESTS FAILED: $(basename "$e") (release profile, clean environment)"; return 1; }
  done <<< "$exes"
  echo "RELEASE-TESTS $n binaries passed in release under env -i"
}
run S1f release-clean-env-tests pass - "$ROOT" release_tests "$ROOT"
# S1g (syntax): shipped source (src/ minus the spec files in spec-paths.txt) may not branch on a judging context.
# Allowed: `#[cfg(test)]` / `#[cfg(kani)]` directly on a `mod` item (the spec modules). Flagged: any other
# cfg/cfg!/cfg_attr naming test, debug_assertions, kani, fuzzing, clippy, miri, coverage, and string literals
# naming CARGO_* or RUST_TEST* variables (runtime "am I under cargo?" checks). Heuristic: macros or concat! can
# hide a fork from this scan; S1f is the behavioural check behind it.
judge_forks() { # <crate dir>
  # the files to scan are the files the SHIPPED build compiles (rustc dep-info of a release lib+bins build):
  # #[path = "../x.rs"] modules and include!() files outside src/ are in it; src/ is walked as well
  local t; t="$(mktemp -d "${SANDBOX_WORK:-${TMPDIR:-/tmp}}/s1g.XXXXXX")"
  ( cd "$1" && CARGO_TARGET_DIR="$t" cargo build --release --locked --lib --bins -q ) >/dev/null 2>&1 \
    || { echo "JUDGE-FORK shipped build failed (cannot list the compiled sources)"; return 1; }
  "$PY" - "$1" "$t" "${CARGO_HOME:-$HOME/.cargo}" <<'PY'
import os, re, sys
root = sys.argv[1]
def compiled_sources(target, crate_root, cargo_home):
    found = set()
    for d, _, names in os.walk(target):
        for nm in names:
            if not nm.endswith(".d"): continue
            try: text = open(os.path.join(d, nm)).read()
            except OSError: continue
            for line in text.splitlines():
                if ":" not in line: continue
                for p in line.split(":", 1)[1].replace("\\ ", "\0").split():
                    p = p.replace("\0", " ")
                    p = os.path.realpath(p if os.path.isabs(p) else os.path.join(crate_root, p))
                    # every compiled input, whatever its extension: include!("x.inc") and #[path = "x.txt"] are Rust too
                    if os.path.isfile(p) and not p.startswith(os.path.realpath(cargo_home) + os.sep):
                        found.add(p)
    return found
compiled = compiled_sources(sys.argv[2], root, sys.argv[3])
if not compiled: sys.exit("JUDGE-FORK no compiled source found in the shipped build's dep-info")
spec = set()
try:
    for line in open(os.path.join(root, "spec-paths.txt")):
        line = line.strip()
        if line and not line.startswith("#"): spec.add(os.path.normpath(line))
except OSError:
    pass
def is_spec(rel):
    return any(rel == p or rel.startswith(p + os.sep) for p in spec)
JUDGE = r"\b(test|debug_assertions|kani|fuzzing|clippy|miri|coverage)\b"
CFG = re.compile(r"(#!?\[\s*cfg(_attr)?\s*\(|\bcfg!\s*\()")
ALLOWED_ATTR = re.compile(r"^\s*#\[\s*cfg\s*\(\s*(test|kani)\s*\)\s*\]\s*$")
MOD = re.compile(r"^\s*(pub(\([^)]*\))?\s+)?mod\s+\w+")
ENVLIT = re.compile(r'"(CARGO_[A-Z0-9_]*|RUST_TEST[A-Z0-9_]*)"')
def rust_blank(text):
    """Rust lexing just far enough to blank comments (nested /* */ too), string, byte, raw-string and char
    literals - newlines kept, delimiters kept - so cfg expressions are cut by real parentheses only.
    Char literal vs lifetime as rustc decides: ' + escape or ' + one char + ' is a char literal, else a lifetime.
    Returns (code, problem); an unterminated comment or literal is a problem (fail closed)."""
    out, k, n = [], 0, len(text)
    blank = lambda seg: "".join(ch if ch == "\n" else " " for ch in seg)
    while k < n:
        c = text[k]
        if text.startswith("//", k):
            e = text.find("\n", k); e = n if e < 0 else e
            out.append(blank(text[k:e])); k = e; continue
        if text.startswith("/*", k):
            depth, e = 1, k + 2
            while e < n and depth:
                if text.startswith("/*", e): depth += 1; e += 2
                elif text.startswith("*/", e): depth -= 1; e += 2
                else: e += 1
            if depth: return None, f"unterminated block comment at offset {k}"
            out.append(blank(text[k:e])); k = e; continue
        m = re.match(r'(b|c)?r(#*)"', text[k:]) if c in "brc" and (k == 0 or not (text[k - 1].isalnum() or text[k - 1] == "_")) else None
        if m:
            close = '"' + m.group(2); e = text.find(close, k + m.end())
            if e < 0: return None, f"unterminated raw string at offset {k}"
            e += len(close); out.append(text[k] + blank(text[k + 1:e - 1]) + text[e - 1]); k = e; continue
        if c == '"' or (c in "bc" and text.startswith('"', k + 1) and (k == 0 or not (text[k - 1].isalnum() or text[k - 1] == "_"))):
            s0 = k if c == '"' else k + 1; e = s0 + 1
            while e < n and text[e] != '"': e += 2 if text[e] == "\\" else 1
            if e >= n: return None, f"unterminated string at offset {k}"
            out.append(text[k:s0 + 1] + blank(text[s0 + 1:e]) + '"'); k = e + 1; continue
        if c == "'":
            if text.startswith("\\", k + 1):
                e = k + 3   # the backslash AND the escaped char ('\\', '\'') are one unit
                while e < n and text[e] != "'": e += 2 if text[e] == "\\" else 1
                if e >= n: return None, f"unterminated char literal at offset {k}"
                out.append("'" + blank(text[k + 1:e]) + "'"); k = e + 1; continue
            if k + 2 < n and text[k + 2] == "'" and text[k + 1] != "\n":
                out.append("' '"); k += 3; continue
            out.append(c); k += 1; continue   # a lifetime
        out.append(c); k += 1
    return "".join(out), None
# cfg, cfg_attr, cfg! and the cfg_select!/cfg_match! macros, with ANY invocation delimiter: cfg!(..), cfg![..], cfg!{..}
START = re.compile(r"(#!?\[\s*)?\bcfg(_attr|_select|_match)?\s*(!\s*)?([\(\[\{])")
PAIR = {"(": ")", "[": "]", "{": "}"}
bad = []; files = 0
walked = {os.path.realpath(os.path.join(d, nm)) for d, _, names in os.walk(os.path.join(root, "src")) for nm in names if nm.endswith(".rs")}
for path in sorted(compiled | walked):
        name = os.path.basename(path); rel = os.path.relpath(path, os.path.realpath(root))
        if is_spec(rel): continue
        files += 1
        try: raw = open(path, encoding="utf-8").read()
        except UnicodeDecodeError:
            files -= 1; continue          # not UTF-8: rustc cannot compile it as source (include_bytes! data)
        lits = raw
        text, problem = rust_blank(raw)
        if problem:
            if path.endswith(".rs"): bad.append(f"{rel}: cannot read safely ({problem})"); continue
            # a non-.rs input that does not lex as Rust is data (include_str!: README, ...): scan its raw text for
            # cfg forks anyway (over-approximation), skip the literal check
            text, lits = raw, ""
        # whole cfg expressions, balanced parentheses, across lines (a multi-line #[cfg(any(test, kani))] too)
        for m in START.finditer(text):
            k, stack = m.end(), [PAIR[m.group(4)]]
            while k < len(text) and stack:
                ch = text[k]
                if ch in PAIR: stack.append(PAIR[ch])
                elif ch in ")]}":
                    if ch != stack.pop(): stack = []; k = len(text); break   # mismatched: take the rest (fail closed)
                k += 1
            expr = text[m.start():k]
            if not re.search(JUDGE, expr): continue
            line = text.count("\n", 0, m.start()) + 1
            first = raw.split("\n")[line - 1].strip()
            if m.group(1) and not m.group(2) and m.group(4) == "(" and re.fullmatch(r"cfg\s*\(\s*(test|kani)\s*\)", text[m.end(1) if m.group(1) else m.start():k].strip()):
                rest = text[k:].lstrip()
                if rest.startswith("]"):
                    after = rest[1:].lstrip()
                    while after.startswith("#["):
                        after = after[after.find("]") + 1:].lstrip()
                    if MOD.match(after): continue
            bad.append(f"{rel}:{line}: {first}")
        for i, l in enumerate(lits.split("\n")):
            if ENVLIT.search(l): bad.append(f"{rel}:{i + 1}: {raw.split(chr(10))[i].strip()}")
if files == 0: sys.exit("JUDGE-FORK no shipped source found under src/")
for b in bad: print("JUDGE-FORK " + b)
if bad: sys.exit(1)
print(f"JUDGE-FORK none in {files} shipped source files")
PY
}
run S1g no-judge-forks pass - "$ROOT" judge_forks "$ROOT"
# S1c in two steps so the log says WHY it failed (cargo-llvm-cov alone exits 1 without a reason).
coverage_gate() { # <min line %>
  # The profile is written by the process under test, so the measurement is only as good as what that process
  # cannot do (#45 item 7): S1i forbids unsafe code in every target (no direct write to the counter section),
  # the test binaries run jailed WITHOUT procfs (no /proc/self/mem), each binary gets its own profile path that
  # the runtime rewrites at exit (run-<pid>.profraw; in the jail's pid namespace the test binary is pid 2, child
  # processes such as the CLI binary under test get their own), any other file fails the gate, and a binary that
  # does not exit 0 fails the gate. Residual: a crafted run-<n>.profraw posing as a child's profile. Instrumentation, merge and report use the pinned toolchain's llvm-tools directly.
  local min="$1"
  (
    set -o pipefail
    ct="$CARGO_TARGET_DIR/coverage"; rm -rf "$ct"; mkdir -p "$ct/prof"
    # -F unsafe_code on the instrumented build itself: S1i (clippy) does not see code under #[cfg(not(clippy))]
    # (Codex P1 on #54, C68); cargo caps lints for registry dependencies, so only workspace code is held to it
    export CARGO_TARGET_DIR="$ct/target" RUSTFLAGS="${RUSTFLAGS:-} -C instrument-coverage --cfg=coverage -F unsafe_code"
    sysroot="$(rustc --print sysroot)" && host="$(rustc -vV | sed -n 's/^host: //p')" && tools="$sysroot/lib/rustlib/$host/bin" &&
      [ -x "$tools/llvm-profdata" ] && [ -x "$tools/llvm-cov" ] || { echo "COVERAGE llvm-tools missing (rustup component add llvm-tools)"; exit 1; }
    exes="$(cargo test --locked --no-run --message-format=json 2>/dev/null | "$PY" -c '
import json, sys
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("reason") == "compiler-message" and (m.get("message") or {}).get("level") == "error":
        print("COVERAGE build error: " + (m["message"].get("message") or ""), file=sys.stderr)
    if m.get("reason") == "compiler-artifact" and m.get("executable"):
        print(("T " if (m.get("profile") or {}).get("test") else "B ") + m["executable"])')" || { echo "COVERAGE build failed"; exit 1; }
    grep -q '^T ' <<< "$exes" || { echo "COVERAGE no test binary built"; exit 1; }
    n=0; objs=()
    while read -r k e; do objs+=(-object "$e"); done <<< "$exes"
    while read -r k e; do
      [ "$k" = T ] || continue
      n=$((n + 1)); pd="$ct/run/$n"; mkdir -p "$pd"
      ( SANDBOX_NOPROC=1 SANDBOX_RW="$pd" sandbox env -i PATH=/usr/bin:/bin LLVM_PROFILE_FILE="$pd/run-%p.profraw" "$e" -q ) ||
        { echo "COVERAGE tests failed: $(basename "$e")"; exit 1; }
      bad="$(find "$pd" -mindepth 1 ! -regex '.*/run-[0-9]+\.profraw' -printf '%f ')"
      [ -z "$bad" ] || { echo "COVERAGE profile tampered: $(basename "$e") left unexpected files: $bad"; exit 1; }
      [ -s "$pd/run-2.profraw" ] || { echo "COVERAGE profile tampered: $(basename "$e") wrote no profile of its own (run-2.profraw)"; exit 1; }
      for f in "$pd"/run-*.profraw; do mv "$f" "$ct/prof/$n-$(basename "$f")"; done
    done <<< "$exes"
    SANDBOX_RW="$ct" sandbox "$tools/llvm-profdata" merge -sparse "$ct"/prof/*.profraw -o "$ct/merged.profdata" || { echo "COVERAGE profile merge failed"; exit 1; }
    SANDBOX_RW="$ct" sandbox "$tools/llvm-cov" export -summary-only -instr-profile="$ct/merged.profdata" "${objs[@]}" \
      -ignore-filename-regex='(/\.cargo/(registry|git)/|/rustc/[0-9a-f]+/|/\.rustup/|(^|/)(tests|examples|benches)/|(^|/)tests\.rs$|/target/)' > "$ct/summary.json" ||
      { echo "COVERAGE report missing"; exit 1; }
    "$PY" - "$ct/summary.json" "$min" "$n" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["data"][0]["totals"]["lines"]
print(f"TOTAL lines {t['covered']}/{t['count']} = {t['percent']:.2f}% ({sys.argv[3]} test binaries, run without procfs)")
sys.exit(0 if t["count"] and t["percent"] >= float(sys.argv[2]) else 3)
PY
    rc=$?; [ "$rc" -eq 0 ] || { [ "$rc" -eq 3 ] && echo "COVERAGE below threshold: lines < $min%" || echo "COVERAGE report unreadable"; exit 1; }
  )
}
# S1i: no unsafe code in any target (lib, bins, tests): a test could otherwise write the coverage counter section
# (__start___llvm_prf_cnts) directly and fake S1c (#45 item 7, C65)
run S1i no-unsafe-code pass - "$ROOT" cargo clippy --locked --all-targets -- -F unsafe_code
run S1c test-coverage pass - "$ROOT" coverage_gate 80
# S1d: mutation testing. Coverage says code RAN; mutants say tests CATCH changes.
# PASS only if no mutant is missed or timed out and at least one was caught (no vacuous pass).
# Exclusions: mutants-exclusions.tsv, "<regex>\t<justification>"; an empty justification is a FAIL.
mutants_gate() {
  local d="$1" out="$2" re why rc; shift 2
  local args=()
  if [ -f "$d/mutants-exclusions.tsv" ]; then
    while IFS=$'\t' read -r re why || [ -n "$re" ]; do
      [[ -z "$re" || "$re" == \#* ]] && continue
      [[ "$why" =~ [^[:space:]] ]] || { echo "MUTANTS exclusion without justification: $re"; return 1; }
      args+=(--exclude-re "$re")
    done < "$d/mutants-exclusions.tsv"
  fi
  rm -rf "$out" 2>/dev/null; mkdir -p "$out"
  ( cd "$d" && unset CARGO_TARGET_DIR && SANDBOX_RW="$out" cargo mutants --test-tool nextest --no-shuffle -o "$out" "${args[@]}" "$@" ); rc=$?
  local o="$out/mutants.out"
  [ -f "$o/outcomes.json" ] || { echo "MUTANTS no outcomes (exit $rc)"; return 1; }
  if [ -s "$o/missed.txt" ]; then sed 's/^/MISSED /' "$o/missed.txt"; return 1; fi
  if [ -s "$o/timeout.txt" ]; then sed 's/^/TIMEOUT /' "$o/timeout.txt"; return 1; fi
  [ -s "$o/caught.txt" ] || { echo "MUTANTS none caught (vacuous)"; return 1; }
  [ "$rc" -eq 0 ] || { echo "MUTANTS cargo-mutants exit $rc"; return 1; }
  echo "MUTANTS caught=$(wc -l < "$o/caught.txt") unviable=$(grep -c . "$o/unviable.txt")"
}
run S1d mutation pass - "$ROOT" mutants_gate "$ROOT" "$WORK/mutants-root"
# S1h "neutral mutant" (#45 item 2): S1d counts a mutant as caught when ANY test fails - a test that only checks
# the source text (a hash of include_str!("lib.rs")) catches every mutant without checking behaviour. Here the
# shipped source gets edits that change its text but not its behaviour - a comment on top of each file and a
# `let _ = <random>u64;` at the start of every function body, the places mutants edit - and the unchanged test
# suite must still pass. A test that fails on a behaviour-preserving edit reads the source, not the behaviour.
neutral_gate() { # <crate dir> <work dir>
  local d="$1" w="$2"
  # part 1 (syntax): spec/test code may not read the shipped source - a test counting tokens of include_str!("lib.rs")
  # survives any neutral edit but still kills mutants. Flagged in spec files and tests/: include_str!/include_bytes!
  # of a .rs path or of a non-literal path, and any string literal naming a .rs file (runtime fs reads).
  "$PY" - "$d" <<'PY' || return 1
import os, re, sys
root = sys.argv[1]
spec = {"tests"}
try:
    for line in open(os.path.join(root, "spec-paths.txt")):
        line = line.strip()
        if line and not line.startswith("#"): spec.add(os.path.normpath(line))
except OSError:
    pass
files = set()
for p in spec:
    full = os.path.join(root, p)
    if os.path.isfile(full) and full.endswith(".rs"): files.add(full)
    elif os.path.isdir(full):
        for d, _, names in os.walk(full):
            files.update(os.path.join(d, n) for n in names if n.endswith(".rs"))
INC = re.compile(r"\binclude_(str|bytes)\s*!\s*[\(\[\{]\s*(\"[^\"]*\")?")
RSLIT = re.compile(r'"[^"\n]*\.rs"')
# include_str!/include_bytes! of source is checked in EVERY .rs file under src/ and tests/ (an inline #[cfg(test)]
# module in a shipped file is test code too); the .rs string-literal rule only in spec files
everything = set(files)
for top in ("src", "tests"):
    for d, _, names in os.walk(os.path.join(root, top)):
        everything.update(os.path.join(d, n) for n in names if n.endswith(".rs"))
bad = []
for p in sorted(everything):
    rel = os.path.relpath(p, root)
    for i, line in enumerate(open(p, encoding="utf-8").read().split("\n"), 1):
        for m in INC.finditer(line):
            if not m.group(2) or m.group(2).endswith('.rs"'): bad.append(f"{rel}:{i}: {line.strip()}")
        if p in files and RSLIT.search(line) and not INC.search(line): bad.append(f"{rel}:{i}: {line.strip()}")
for b in bad: print("NEUTRAL spec reads source text: " + b)
sys.exit(1 if bad else 0)
PY
  rm -rf "$w"; mkdir -p "$w/crate"
  ( cd "$d" && tar --exclude=./target --exclude=./.git -cf - . ) | ( cd "$w/crate" && tar -xf - ) || { echo "NEUTRAL copy failed"; return 2; }
  "$PY" - "$w/crate" <<'PY' || return 2
import os, random, re, sys
root = sys.argv[1]
spec = set()
try:
    for line in open(os.path.join(root, "spec-paths.txt")):
        line = line.strip()
        if line and not line.startswith("#"): spec.add(os.path.normpath(line))
except OSError:
    pass
rng = random.SystemRandom()
edited = bodies = 0
for d, _, names in os.walk(os.path.join(root, "src")):
    for nm in sorted(names):
        if not nm.endswith(".rs"): continue
        p = os.path.join(d, nm); rel = os.path.relpath(p, root)
        if any(rel == q or rel.startswith(q + os.sep) for q in spec): continue
        text = open(p, encoding="utf-8").read()
        # blank comments/strings/chars (same rules as S1g's lexer, kept short here) to find `fn` bodies safely
        code = re.sub(r"//[^\n]*", lambda m: " " * len(m.group()), text)
        code = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group()), code, flags=re.S)
        code = re.sub(r'"(?:\\.|[^"\\])*"', lambda m: '"' + " " * (len(m.group()) - 2) + '"', code)
        inserts = []
        for m in re.finditer(r"\bfn\s+\w+", code):
            k, depth = m.end(), 0
            while k < len(code):
                c = code[k]
                if c in "([<": depth += 1
                elif c in ")]>" and not code.startswith("->", k - 1): depth -= 1
                elif c == ";" and depth <= 0: k = -1; break          # declaration without a body
                elif c == "{" and depth <= 0: break
                k += 1
            if k < 0 or k >= len(code): continue
            inserts.append(k + 1)
        for pos in sorted(inserts, reverse=True):
            n = rng.randrange(1, 2**31)
            text = text[:pos] + " " + rng.choice([f"let _ = {n}u64;", f"let _n{n:x} = ();", f"if {n} == 0 {{ let _ = (); }}", f"{{ let _ = [{n}u32; 1]; }}"]) + " " + text[pos:]
        bodies += len(inserts)
        text = f"// neutral edit {rng.randrange(2**63):x}: behaviour unchanged\n" + text
        open(p, "w", encoding="utf-8").write(text); edited += 1
if edited == 0: sys.exit("NEUTRAL no shipped source file to edit")
print(f"NEUTRAL edited {edited} files, {bodies} function bodies")
PY
  ( cd "$w/crate" && CARGO_TARGET_DIR="$w/target" cargo test --locked -q 2>&1 | tail -15; exit "${PIPESTATUS[0]}" ) \
    || { echo "NEUTRAL tests fail on a behaviour-preserving edit: they read the source text, not the behaviour"; return 1; }
  echo "NEUTRAL tests pass on behaviour-preserving edits"
}
run S1h neutral-mutant pass - "$ROOT" neutral_gate "$ROOT" "$WORK/neutral-root"
# --- S2: supply chain ---
run S2a deny pass - "$ROOT" cargo deny --locked check
run S2b audit pass - "$ROOT" cargo audit
# S2c: every third-party dependency is audited by a trusted party (cargo-vet, gap G10). Jailed and offline
# (--frozen); cargo-vet locks its store, so it reads a writable copy of supply-chain/ (--locked: never edits it).
vet_gate() { # <project dir>
  [ -d "$1/supply-chain" ] || { echo "VET no supply-chain/ store in $1 (cargo vet init)"; return 1; }
  local st; st="$(mktemp -d "$WORK/vet.XXXXXX")" && cp -r "$1/supply-chain/." "$st/" || return 1
  SANDBOX_RW="$st" cargo vet --locked --frozen --store-path "$st"
}
run S2c vet pass - "$ROOT" vet_gate "$ROOT"

# --- A8: gate self-test. Each gate must FAIL on a known-bad input, for the RIGHT reason ---
CAN="$WORK/canaries"; mkdir -p "$CAN"
mk() { mkdir -p "$CAN/$1"; cp -r "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/src" "$ROOT/deny.toml" "$CAN/$1/"
  # canary copies live outside the project tree: carry the pinned toolchain so they use the same rustc as the real gates
  if [ -f "${PIN_DIR%/}/rust-toolchain.toml" ]; then cp "${PIN_DIR%/}/rust-toolchain.toml" "$CAN/$1/"; fi; }
mk fmt;    printf 'pub fn   ugly( ) {}\n' >> "$CAN/fmt/src/lib.rs"
CARGO_TARGET_DIR="$CAN/fmt/target" run C1 canary-fmt fail 'Diff in' "$CAN/fmt" cargo fmt --all -- --check
mk clippy; printf '\npub fn is_empty_vec(v: &[u32]) -> bool { v.len() == 0 }\n' >> "$CAN/clippy/src/lib.rs"
CARGO_TARGET_DIR="$CAN/clippy/target" run C2 canary-clippy fail 'len_zero' "$CAN/clippy" cargo clippy --all-targets -- -D warnings
mk nopanic; printf '\npub fn first_byte(v: &[u8]) -> u8 { v[0] }\n' >> "$CAN/nopanic/src/lib.rs"
CARGO_TARGET_DIR="$CAN/nopanic/target" run C26 canary-panic-construct fail 'indexing may panic' "$CAN/nopanic" cargo clippy -- -D warnings "${NOPANIC[@]}"
# C36-C41: fork canaries. Generic for any crate: each appends a forked function (plus, for S1f, a unit test
# that holds only in the judged variant) to the crate's src/lib.rs.
fork_canary() { # <dir> <function body> [with-test]
  mk "$1"; [ -f "$ROOT/spec-paths.txt" ] && cp "$ROOT/spec-paths.txt" "$CAN/$1/"
  printf '\n#[must_use]\npub fn canary_fork() -> u32 {\n%s\n}\n' "$2" >> "$CAN/$1/src/lib.rs"
  if [ "${3:-}" = with-test ]; then
    printf '\n#[cfg(test)]\nmod canary_fork_spec {\n    #[test]\n    fn canary_fork_is_one() {\n        assert_eq!(super::canary_fork(), 1);\n    }\n}\n' >> "$CAN/$1/src/lib.rs"
  fi
}
# C36: env fork - correct under `cargo test`, wrong in the shipped binary: only S1f's direct run sees it
fork_canary fork-env '    if std::env::var_os(concat!("CARGO_", "MANIFEST_DIR")).is_some() { 1 } else { 2 }' with-test
CARGO_TARGET_DIR="$CAN/fork-env/target" run C36 canary-env-fork-release fail 'RELEASE-TESTS FAILED' "$CAN/fork-env" release_tests "$CAN/fork-env"
# C37: cfg(test) fork - the tests see one body, the shipped crate the other
fork_canary fork-test '    #[cfg(test)]
    return 1;
    #[cfg(not(test))]
    2'
run C37 canary-cfg-test-fork fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(test\)\]' "$CAN/fork-test" judge_forks "$CAN/fork-test"
# C38/C39: debug_assertions fork - S1g flags it; S1f catches it too (release turns debug_assertions off)
fork_canary fork-debug '    if cfg!(debug_assertions) { 1 } else { 2 }' with-test
run C38 canary-debug-assertions-fork fail '^JUDGE-FORK src/lib.rs:[0-9]+: if cfg!\(debug_assertions\)' "$CAN/fork-debug" judge_forks "$CAN/fork-debug"
CARGO_TARGET_DIR="$CAN/fork-debug/target" run C39 canary-debug-assertions-fork-release fail 'RELEASE-TESTS FAILED' "$CAN/fork-debug" release_tests "$CAN/fork-debug"
# C40/C41: a fork only Kani / only clippy would see
fork_canary fork-kani '    #[cfg(kani)]
    return 1;
    #[cfg(not(kani))]
    2'
run C40 canary-cfg-kani-fork fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(kani\)\]' "$CAN/fork-kani" judge_forks "$CAN/fork-kani"
fork_canary fork-clippy '    #[cfg(not(clippy))]
    return 2;
    #[cfg(clippy)]
    1'
run C41 canary-cfg-clippy-fork fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(not\(clippy\)\)\]' "$CAN/fork-clippy" judge_forks "$CAN/fork-clippy"
# C42: the same fork with the cfg expression spread over several lines (the scan reads whole expressions)
fork_canary fork-multiline '    #[cfg(any(
        test,
        kani
    ))]
    return 1;
    #[cfg(not(any(test, kani)))]
    2'
run C42 canary-multiline-cfg-fork fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(any\($' "$CAN/fork-multiline" judge_forks "$CAN/fork-multiline"
# C43: a char literal '"' before the fork must not hide it (no string/comment skipping in the scan)
fork_canary fork-charlit "    const _Q: char = '\"';
    #[cfg(test)]
    return 1;
    #[cfg(not(test))]
    2"
run C43 canary-fork-after-char-literal fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(test\)\]' "$CAN/fork-charlit" judge_forks "$CAN/fork-charlit"
# C44: a comment holding ')' inside the cfg expression must not cut it short before the judging identifier
fork_canary fork-comment-paren '    #[cfg(any(/* )) */ test))]
    return 1;
    #[cfg(not(/* )) */ test))]
    2'
run C44 canary-fork-comment-paren fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(any\(/\* \)\) \*/ test\)\)\]' "$CAN/fork-comment-paren" judge_forks "$CAN/fork-comment-paren"
# C45: a backslash char literal before the fork and another char literal after it (escape consumed as a unit)
fork_canary fork-backslash "    const _B: char = '\\\\';
    #[cfg(test)]
    return 1;
    #[cfg(not(test))]
    let _q: char = 'q';
    #[cfg(not(test))]
    2"
run C45 canary-fork-after-backslash-char fail '^JUDGE-FORK src/lib.rs:[0-9]+: #\[cfg\(test\)\]' "$CAN/fork-backslash" judge_forks "$CAN/fork-backslash"
# C46: the fork lives in a #[path = "../..."] module outside src/ - the scan follows what the build compiles
mk fork-path; [ -f "$ROOT/spec-paths.txt" ] && cp "$ROOT/spec-paths.txt" "$CAN/fork-path/"
printf '#[must_use]\npub fn value() -> u32 {\n    #[cfg(test)]\n    return 1;\n    #[cfg(not(test))]\n    2\n}\n' > "$CAN/fork-path/impl_outside_src.rs"
printf '\n#[path = "../impl_outside_src.rs"]\nmod imp;\n#[must_use]\npub fn canary_fork() -> u32 {\n    imp::value()\n}\n' >> "$CAN/fork-path/src/lib.rs"
CARGO_TARGET_DIR="$CAN/fork-path/target" run C46 canary-fork-in-path-module fail '^JUDGE-FORK impl_outside_src.rs:[0-9]+: #\[cfg\(test\)\]' "$CAN/fork-path" judge_forks "$CAN/fork-path"
# C47: cfg! invoked with brackets and braces - every delimiter of the built-in macro is scanned
fork_canary fork-delims '    if cfg![test] { return 1; }
    if cfg!{test} { 1 } else { 2 }'
run C47 canary-cfg-bang-other-delimiters fail '^JUDGE-FORK src/lib.rs:[0-9]+: if cfg!\[test\]' "$CAN/fork-delims" judge_forks "$CAN/fork-delims"
# C48: the fork lives in an include!()d file without the .rs extension
mk fork-inc; [ -f "$ROOT/spec-paths.txt" ] && cp "$ROOT/spec-paths.txt" "$CAN/fork-inc/"
printf '#[must_use]\npub fn canary_fork() -> u32 {\n    #[cfg(test)]\n    return 1;\n    #[cfg(not(test))]\n    2\n}\n' > "$CAN/fork-inc/implementation.inc"
printf '\ninclude!("../implementation.inc");\n' >> "$CAN/fork-inc/src/lib.rs"
CARGO_TARGET_DIR="$CAN/fork-inc/target" run C48 canary-fork-in-included-file fail '^JUDGE-FORK implementation.inc:[0-9]+: #\[cfg\(test\)\]' "$CAN/fork-inc" judge_forks "$CAN/fork-inc"
# C49: a test that only hashes the shipped source catches every mutant (S1d passes) - S1h must fail it. The read
# is built so the spec scan cannot see it (no .rs literal, no include_str!): the behaviour-preserving edit catches it
mk neutral-hash; [ -f "$ROOT/spec-paths.txt" ] && cp "$ROOT/spec-paths.txt" "$CAN/neutral-hash/"
NH="$("$PY" -c 'import sys; h=0
for b in open(sys.argv[1],"rb").read(): h=(h*31+b)%(1<<64)
print(h)' "$CAN/neutral-hash/src/lib.rs")"
printf '\n#[cfg(test)]\nmod canary_source_hash {\n    #[test]\n    fn source_unchanged() {\n        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join(["lib", "rs"].join("."));\n        let owned = std::fs::read_to_string(path).unwrap_or_default();\n        let all = owned.as_str();\n        let src = &all[..all.find("\\n#[cfg(test)]\\nmod canary_source_hash").unwrap_or(all.len())];\n        let h = src.bytes().fold(0u64, |h, b| h.wrapping_mul(31).wrapping_add(u64::from(b)));\n        assert_eq!(h, %s);\n    }\n}\n' "$NH" >> "$CAN/neutral-hash/src/lib.rs"
run C49 canary-source-hash-test fail '^NEUTRAL tests fail on a behaviour-preserving edit' "$CAN/neutral-hash" neutral_gate "$CAN/neutral-hash" "$WORK/neutral-c49"
# C50: a test that counts tokens of the shipped source survives every neutral edit - the spec scan must flag it
mk neutral-count; [ -f "$ROOT/spec-paths.txt" ] && cp "$ROOT/spec-paths.txt" "$CAN/neutral-count/"
printf '\n#[cfg(test)]\nmod canary_source_count {\n    #[test]\n    fn operators_unchanged() {\n        assert!(include_str!("lib.rs").matches("fn ").count() > 0);\n    }\n}\n' >> "$CAN/neutral-count/src/lib.rs"
mkdir -p "$CAN/neutral-count/tests"; printf '#[test]\nfn counts() {\n    assert!(include_str!("../src/lib.rs").contains("fn "));\n}\n' > "$CAN/neutral-count/tests/count.rs"
run C50 canary-test-reads-source fail '^NEUTRAL spec reads source text: src/lib.rs:[0-9]+: .*include_str' "$CAN/neutral-count" neutral_gate "$CAN/neutral-count" "$WORK/neutral-c50"
# C33: the code under test switches the lint off with #[allow]; with -F (forbid) that is itself an error
mk nopanic-allow; printf '\n#[allow(clippy::indexing_slicing)]\n#[must_use]\npub fn canary_first(v: &[u8]) -> u8 {\n    v[0]\n}\n' >> "$CAN/nopanic-allow/src/lib.rs"
CARGO_TARGET_DIR="$CAN/nopanic-allow/target" run C33 canary-lint-allow-overridden fail 'incompatible with previous forbid' "$CAN/nopanic-allow" cargo clippy -- -D warnings "${NOPANIC[@]}"
# C28: from inside the jail, every protected path must refuse a write (zero-byte append / temp file).
PROTECT=("$RES" "$EV" "$SD" "$ROOT/.git" "$ROOT/threat-model.tsv" "$ROOT/ext-controls.tsv" "$ROOT/supply-chain" "$ROOT/claims.tsv" "${CARGO_HOME:-$HOME/.cargo}/config.toml" "$CAN"
         "${CARGO_HOME:-$HOME/.cargo}/registry")
[ -n "${GITHUB_ENV:-}" ] && PROTECT+=("$GITHUB_ENV" "$GITHUB_OUTPUT")
run C28 canary-sandbox-blocks-writes fail '^SANDBOX all writes blocked' "$ROOT" sandbox_probe "${PROTECT[@]}"
# C29: the real attack path - a planted #[test] run by `cargo test` tries to open results.tsv for append.
# Blocked means read-only (EROFS: evidence visible, as under GITHUB_WORKSPACE in CI) or absent (ENOENT: evidence under the
# hidden $HOME, as in a local clone). The planted test runs through S1f's own check (release_tests: release build, jail,
# env -i), so C29 breaks the guard S1f relies on (#45 item 4); the path is compiled in, env -i keeps no variables.
[ -f "$RES" ] || { echo "C29 setup: $RES missing" >&2; exit 1; }
mk tamper; printf '\n#[test]\nfn canary_tamper() {\n    let p = "%s";\n    assert!(!p.is_empty(), "TAMPER no path");\n    if let Err(e) = std::fs::OpenOptions::new().append(true).open(p) { panic!("TAMPER blocked: {e}"); }\n}\n' "$RES" >> "$CAN/tamper/src/lib.rs"
CARGO_TARGET_DIR="$CAN/tamper/target" run C29 canary-test-cannot-touch-evidence fail 'TAMPER blocked: (Read-only file system \(os error 30\)|No such file or directory \(os error 2\))' "$CAN/tamper" release_tests "$CAN/tamper"
# C30: a leftover mock / `unset -f` that leaves an unjailed cargo must stop the next gate, not run it unjailed.
cargo() { command cargo "$@"; }
run C30 canary-jail-disarmed fail '^JAIL disarmed before C30' "$ROOT" true
sandbox_enable
# C31: jailed code reaches no unix socket (docker.sock = full escape; read-only binds do not stop connect())
# and no network. The host opens its own decoy socket in /tmp so the probe is meaningful on any machine.
run C31 canary-sandbox-no-sockets-no-network fail '^SANDBOX no socket or network reachable' "$ROOT" sandbox_probe_sockets "$(mktemp -d)"
# C34: a writable path that is (or passes through) a symlink - e.g. a committed fuzz/artifacts/<t> -> $RUNNER_TEMP -
# would re-mount the link's target writable; the jail must refuse to start.
mkdir "$HOST/c34-target"; mkdir "$CAN/c34"; ln -s "$HOST/c34-target" "$CAN/c34/artifacts"
SANDBOX_RW="$CAN/c34/artifacts" run C34 canary-symlinked-writable-path fail '^SANDBOX writable path is or passes through a symlink' "$CAN/c34" sandbox true
# C35: secrets in the caller's environment and in $HOME are invisible to jailed code (it could print them into
# the logs and evidence). A fake secret in the env and a fake key file in $HOME must not be readable.
secret_probe() {
  local key="$HOME/.ci-local-fake-secret-$$"; printf 'FAKE-KEY\n' > "$key"
  local out; out="$(CI_LOCAL_FAKE_SECRET=FAKE-ENV sandbox sh -c 'echo "env=${CI_LOCAL_FAKE_SECRET:-}"; cat "$1" 2>/dev/null' _ "$key")"
  rm -f "$key"
  if grep -q 'FAKE-' <<< "$out"; then echo "SANDBOX secret visible: $out"; return 0; fi
  echo "SANDBOX secrets hidden (env cleared, \$HOME empty)"; return 1
}
run C35 canary-sandbox-hides-secrets fail '^SANDBOX secrets hidden' "$ROOT" secret_probe
# C32: a checkout-controlled .cargo/config.toml rustc-wrapper must never run outside the jail - not even
# during fetch / metadata / deny / audit, which run unjailed (network) from a neutral directory.
# Non-vacuous: the same wrapper must have run INSIDE the jail during the build (marker in the target dir).
wrapper_probe() { # <canary crate dir>
  local d="$1" out="$HOST/wrapper-ran" inside="$CARGO_TARGET_DIR/wrapper-inside"
  rm -f "$out" "$inside"; mkdir -p "$d/.cargo" "$CARGO_TARGET_DIR"
  printf '#!/bin/sh\necho ran >> "%s" 2>/dev/null\necho ran >> "%s" 2>/dev/null\nexec "$@"\n' "$out" "$inside" > "$d/wrap.sh"; chmod +x "$d/wrap.sh"
  printf '[build]\nrustc-wrapper = "%s/wrap.sh"\n' "$d" > "$d/.cargo/config.toml"
  ( cd "$d" && cargo fetch --locked; cargo metadata --format-version 1 >/dev/null; cargo deny --locked check; cargo audit; cargo build --locked ) >/dev/null 2>&1
  if [ -s "$out" ]; then echo "WRAPPER ran outside the jail ($(wc -l < "$out") times)"; return 0; fi
  [ -s "$inside" ] || { echo "WRAPPER probe vacuous: the wrapper did not run inside the jail either"; return 2; }
  echo "WRAPPER contained: checkout config ran code only inside the jail"; return 1
}
mk wrapper; CARGO_TARGET_DIR="$CAN/wrapper/target" run C32 canary-checkout-wrapper-only-jailed fail '^WRAPPER contained' "$CAN/wrapper" wrapper_probe "$CAN/wrapper"
mk test;   printf '\n#[test]\nfn canary_fails() { assert_eq!(1 + 1, 3); }\n' >> "$CAN/test/src/lib.rs"
CARGO_TARGET_DIR="$CAN/test/target" run C3 canary-test fail 'canary_fails' "$CAN/test" cargo nextest run
# C74: a crates.io dependency nobody audited must fail S2c (fetched here, outside the jail, like S0f)
mk vetdep; cp -r "$ROOT/supply-chain" "$CAN/vetdep/"
sed -i '/^\[dependencies\]/a itoa = "=1.0.15"' "$CAN/vetdep/Cargo.toml"
( cd "$CAN/vetdep" && cargo fetch ) > "$CAN/vetdep.fetch.log" 2>&1 || true
CARGO_TARGET_DIR="$CAN/vetdep/target" run C74 canary-vet-unaudited-dependency fail 'Vetting Failed|unvetted dependenc' "$CAN/vetdep" vet_gate "$CAN/vetdep"
mk deny;   sed -i 's/^license = .*/license = "GPL-3.0-only"/' "$CAN/deny/Cargo.toml"
grep -q '^license = ' "$CAN/deny/Cargo.toml" || sed -i '/^\[package\]/a license = "GPL-3.0-only"' "$CAN/deny/Cargo.toml"
CARGO_TARGET_DIR="$CAN/deny/target" run C4 canary-deny-license fail 'GPL-3.0' "$CAN/deny" cargo deny check licenses
# C5: a test that runs code without asserting must leave a surviving mutant -> S1d FAILs
mk mutant; printf '\npub fn canary_double(x: u32) -> u32 { x * 2 }\n#[test]\nfn canary_no_assert() { let _ = canary_double(2); }\n' >> "$CAN/mutant/src/lib.rs"
run C5 canary-mutant-survives fail '^MISSED .*canary_double' "$CAN/mutant" mutants_gate "$CAN/mutant" "$WORK/mutants-c5" --re canary_double
# C6: an exclusion without a written justification is rejected
mk mutexcl; printf 'canary_double\t \n' > "$CAN/mutexcl/mutants-exclusions.tsv"
run C6 canary-mutant-exclusion-unjustified fail '^MUTANTS exclusion without justification' "$CAN/mutexcl" mutants_gate "$CAN/mutexcl" "$WORK/mutants-c6"

# C7: a pin that does not match the running rustc must fail S0b
mkdir -p "$CAN/rustpin"; printf '[toolchain]\nchannel = "1.0.0"\n' > "$CAN/rustpin/rust-toolchain.toml"
run C7 canary-rust-pin-mismatch fail '^RUST toolchain mismatch' "$ROOT" rust_pin "$CAN/rustpin/rust-toolchain.toml" "$RUSTC_VERSION"
# C51-C53: a checkout toolchain file must not select a checkout-supplied rustc (#45 item 8). The attack directory holds
# a fake rustc that prints the pinned version and leaves a marker - S0b's version text alone could not tell it apart.
TC="$CAN/toolchain"; mkdir -p "$TC/evil/bin" "$TC/legacy"
printf '#!/bin/sh\ntouch "%s/EXECUTED"\necho "rustc %s (fake)"\n' "$TC" "$RUSTUP_TOOLCHAIN" > "$TC/evil/bin/rustc"
cp "$TC/evil/bin/rustc" "$TC/evil/bin/cargo"; chmod +x "$TC/evil/bin/rustc" "$TC/evil/bin/cargo"
printf '[toolchain]\npath = "%s/evil"\n' "$TC" > "$TC/rust-toolchain.toml"
printf '%s/evil\n' "$TC" > "$TC/legacy/rust-toolchain"
run C51 canary-toolchain-path-key fail '^RUST toolchain file .*: forbidden key path$' "$ROOT" toolchain_check "$TC"
run C52 canary-toolchain-legacy-file fail '^RUST legacy toolchain file not allowed' "$ROOT" toolchain_check "$TC/legacy"
toolchain_probe() { # <dir with a toolchain file> <marker the fake rustc writes>: an unjailed rustc from there must be the pinned one
  rm -f "$2"; local v; v="$( cd "$1" && command rustc --version 2>&1 )"
  if [ -e "$2" ]; then echo "TOOLCHAIN checkout binary executed: $v"; return 0; fi
  echo "TOOLCHAIN checkout path= ignored (RUSTUP_TOOLCHAIN=$RUSTUP_TOOLCHAIN): $v"; return 1
}
run C53 canary-toolchain-path-not-executed fail '^TOOLCHAIN checkout path= ignored' "$ROOT" toolchain_probe "$TC" "$TC/EXECUTED"
run C54 canary-toolchain-legacy-not-executed fail '^TOOLCHAIN checkout path= ignored' "$ROOT" toolchain_probe "$TC/legacy" "$TC/EXECUTED"
# C8: an unreachable threshold must fail S1c with the threshold reason (not a test failure)
mk cov
CARGO_TARGET_DIR="$CAN/cov/target" run C8 canary-coverage-threshold fail '^COVERAGE below threshold' "$CAN/cov" coverage_gate 101
# C65-C67: the code under test must not be able to fake its own coverage (#45 item 7)
mk covunsafe; printf '\n#[cfg(test)]\nmod canary_forge {\n    unsafe extern "C" { static __start___llvm_prf_cnts: u8; static __stop___llvm_prf_cnts: u8; }\n    #[test]\n    fn forge() {\n        unsafe {\n            let s = &raw const __start___llvm_prf_cnts as *mut u64;\n            let e = &raw const __stop___llvm_prf_cnts as usize;\n            for i in 0..(e - s as usize) / 8 { std::ptr::write_volatile(s.add(i), 1); }\n        }\n    }\n}\n' >> "$CAN/covunsafe/src/lib.rs"
CARGO_TARGET_DIR="$CAN/covunsafe/target" run C65 canary-coverage-counter-forge-unsafe fail 'usage of an `unsafe` (block|extern block)|unsafe_code' "$CAN/covunsafe" cargo clippy --all-targets -- -F unsafe_code
# C68 (Codex on #54): the same forger hidden from clippy by #[cfg(not(clippy))] must fail S1c's own build
mk covhide; printf '\n#[cfg(all(test, not(clippy)))]\nmod canary_forge {\n    unsafe extern "C" { static __start___llvm_prf_cnts: u8; static __stop___llvm_prf_cnts: u8; }\n    #[test]\n    fn forge() {\n        unsafe {\n            let s = &raw const __start___llvm_prf_cnts as *mut u64;\n            let e = &raw const __stop___llvm_prf_cnts as usize;\n            for i in 0..(e - s as usize) / 8 { std::ptr::write_volatile(s.add(i), 1); }\n        }\n    }\n}\n' >> "$CAN/covhide/src/lib.rs"
CARGO_TARGET_DIR="$CAN/covhide/target" run C68 canary-coverage-forge-hidden-from-clippy fail '^COVERAGE build error: (usage|declaration) of an .unsafe' "$CAN/covhide" coverage_gate 0
mk covproc; printf '\n#[test]\nfn canary_procmem() {\n    if let Err(e) = std::fs::OpenOptions::new().write(true).open("/proc/self/mem") { panic!("PROCMEM blocked: {e}"); }\n}\n' >> "$CAN/covproc/src/lib.rs"
CARGO_TARGET_DIR="$CAN/covproc/target" run C66 canary-coverage-procmem fail 'PROCMEM blocked: No such file or directory' "$CAN/covproc" coverage_gate 0
mk covextra; printf '\n#[test]\nfn canary_extra_profile() {\n    let p = std::env::var("LLVM_PROFILE_FILE").unwrap_or_default();\n    let _ = std::fs::write(std::path::Path::new(&p).with_file_name("forged.profraw"), b"x");\n}\n' >> "$CAN/covextra/src/lib.rs"
CARGO_TARGET_DIR="$CAN/covextra/target" run C67 canary-coverage-extra-profile fail '^COVERAGE profile tampered: .* left unexpected files: forged\.profraw' "$CAN/covextra" coverage_gate 0
# C9: a lockfile with a known-vulnerable crate (smallvec 1.6.0, RUSTSEC-2021-0003) must fail cargo-audit
mkdir -p "$CAN/audit"; printf 'version = 3\n\n[[package]]\nname = "canary"\nversion = "0.1.0"\ndependencies = ["smallvec"]\n\n[[package]]\nname = "smallvec"\nversion = "1.6.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n' > "$CAN/audit/Cargo.lock"
run C9 canary-audit-known-vulnerability fail 'RUSTSEC-2021-0003' "$CAN/audit" cargo audit -f "$CAN/audit/Cargo.lock"
# C10: code that does not compile must fail S0a
mk build; printf '\npub fn canary_broken( {}\n' >> "$CAN/build/src/lib.rs"
CARGO_TARGET_DIR="$CAN/build/target" run C10 canary-build-broken fail 'unclosed delimiter' "$CAN/build" cargo build --locked

# --- L: Lean stage. Mandatory unless REQUIRE_LEAN=0 AND no Lean project exists (then visibly SKIPPED). ---
export PY="${PY:-python3}"
echo "require_lean=${REQUIRE_LEAN:-1} | python: $(command -v "$PY" >/dev/null && "$PY" --version 2>&1 | sed -n 1p || echo none)" >> "$EV/env.txt"
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
  lean_audit() { local d="$1" mods m audit out
    mods="$(lean_modules "$d")" || return 2
    [ -n "$mods" ] || { echo "audit: no lean_lib in lakefile.toml"; return 2; }
    # the audit script and its output live in $HOST: jailed lake/lean (which may run project code at
    # elaboration) can read the script but neither replace it nor plant a symlink where the host writes
    audit="$(mktemp "$HOST/ZzAuditXXXXXX.lean")" || return 2
    out="$(mktemp "$HOST/axioms.XXXXXX")" || return 2
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
  let mut nonstd : Array Name := #[]
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
    -- only Lean's three standard axioms: a user `axiom cheat : ∀ p, p` would prove anything without sorryAx
    if axs.any (fun a => a != ``sorryAx && a != ``propext && a != ``Classical.choice && a != ``Quot.sound) then
      nonstd := nonstd.push name
  logInfo m!"AUDIT theorems={n}"
  if n == 0 then throwError "AUDIT found no theorems"
  unless bad.isEmpty do throwError m!"AUDIT sorryAx in {bad}"
  unless nonstd.isEmpty do throwError m!"AUDIT non-standard axiom in {nonstd}"
#audit_axioms
LEAN
    } >| "$audit" || return 2
    ( cd "$d" && { lean_build "$d" || { echo "AUDIT build failed"; exit 3; }; } && "${LX[@]}" lake env lean "$audit" ) >| "$out" 2>&1
    local rc=$?
    rm "$audit" || return 2
    # copy for the readers in $d only now that no jailed process is left; rm first (a planted symlink is replaced, not followed)
    rm -rf "$d/axioms.out" && cp "$out" "$d/axioms.out" || return 2
    cat "$out"; return "$rc"; }
  # set -C: the canary scripts' own `> file` writes in a jail-writable dir refuse to follow a planted file/symlink
  AUDIT="set -C; $(declare -f lean_audit lean_modules lean_build); $(declare -p LX HOST)"
  run L2 lean-axiom-audit pass - "$LW" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$LW"
  grep -oE '^AUDIT theorem [^ ]+' "$LW/axioms.out" | awk '{print $3}' | sort -u > "$EV/lean-theorems.txt"
  run L3 lean-no-sorry-text pass - "$LW" bash -c "$(declare -f lean_text); lean_text '$LW'"
  # L4: Lean code runs at elaboration (#eval IO.FS.writeFile ...) in the jail's writable $LW: what was built and
  # audited must still be byte-identical to the PR's Lean sources, or the evidence is about other text.
  lean_same() { diff -rq --exclude=.lake --exclude=axioms.out --exclude=lake-manifest.json "$1" "$2" && echo "LEAN sources unchanged by the build"; }
  run L4 lean-sources-unchanged pass - "$ROOT" lean_same "$LSRC" "$LW"
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
  mkL laxiom; printf '\naxiom canary_cheat : ∀ (p : Prop), p\ntheorem canary_by_axiom : (1 : Nat) = 2 := canary_cheat _\n' >> "$CAN/laxiom/$ROOTFILE"
  run CL38 canary-lean-user-axiom fail "AUDIT non-standard axiom in \\[canary_by_axiom" "$CAN/laxiom" bash -c "$AUDIT; lean_audit \"\$1\"" _ "$CAN/laxiom"
  mkL lrewrite; printf '\n#eval IO.FS.writeFile "%s" "-- rewritten during elaboration\\n"\n' "$ROOTFILE" >> "$CAN/lrewrite/$ROOTFILE"
  run CL39 canary-lean-rewrites-itself fail '^Files .* differ' "$ROOT" bash -c "$AUDIT; $(declare -f lean_same); ( lean_build \"\$1\" ) >/dev/null 2>&1; lean_same \"\$2\" \"\$1\"" _ "$CAN/lrewrite" "$LSRC"
  mkL lwrong; printf '\ntheorem canary_wrong : (1 : Nat) = 2 := by rfl\n' >> "$CAN/lwrong/$ROOTFILE"
  run CL2 canary-lean-false-proof fail 'canary_wrong|rfl. failed' "$CAN/lwrong" lean_build "$CAN/lwrong"   # L1's check
  # CL3: an annotated theorem missing from proof-map.tsv must be reported (discovery covers @[attr])
  mkL lunmap; printf '\n@[simp] theorem canary_unmapped : (2 : Nat) + 2 = 4 := rfl\n' >> "$CAN/lunmap/$ROOTFILE"
  # discovery as for X1 (lean_audit -> theorem list), then X1's own check on the canary's list
  ( cd "$CAN/lunmap" && bash -c "$AUDIT; lean_audit \"\$1\"" _ "$CAN/lunmap" >/dev/null 2>&1; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print $3}' | sort -u > "$CAN/lunmap-theorems.txt" ) || true
  run CL3 canary-unmapped-annotated-theorem fail '^unmapped theorem: canary_unmapped' "$ROOT" bash -c "$(declare -f pm_check); pm_check '$CAN/lunmap-theorems.txt' proof-map.tsv"
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
  JAIL_MOCK=1 run CL16 canary-test-output-is-not-summary fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  cargo() { printf 'test result: ok. 1 passed; 0 failed; 0 ignored;\n'; return 1; }
  JAIL_MOCK=1 run CL17 canary-cargo-status fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  cargo() { printf 'test result: ok. 11 passed; 0 failed; 0 ignored;\n'; }
  JAIL_MOCK=1 run CL18 canary-exact-test-count fail '^rust test missing/failed: tests::adds' "$ROOT" pm_tests "$CAN/maps/valid.tsv"
  sandbox_enable   # restore the jailed cargo (unset -f would leave the real, unjailed one)
  run CL19 canary-command-is-not-output fail '^reason absent from tool output' "$ROOT" bash -c "
    $(declare -f run)
    EV='$CAN/witness'; RES='$CAN/witness/inner.tsv'; WORK='$CAN/witness'
    run inner command-reason fail COMMAND_ONLY_REASON '$ROOT' bash -c 'exit 1' COMMAND_ONLY_REASON
    if grep -q FAIL_WRONG_REASON \"\$RES\"; then echo 'reason absent from tool output'; exit 1; fi"
  printf 'id\tstep\texpect\texit\treason_check\tverdict\n' > "$CAN/witness/results.tsv"
  run CL20 canary-missing-witness-row fail '^witness missing gate: L2' "$ROOT" witness_check "$CAN/witness/results.tsv" L2
  printf 'L2\tlean-audit\tpass\t0\tn/a\tPASS\n' >> "$CAN/witness/results.tsv"
  run CL21 canary-checksum-failure fail '^witness checksum failed' "$ROOT" seal_evidence "$CAN/witness" L2
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
  JAIL_MOCK=1 run CL25 canary-version-command-status fail '^LEAN version command failed' "$ROOT" lean_version 'leanprover/lean4:v4.35.0'
  sandbox_enable   # restore the jailed elan
  # CL37: elaboration may plant axioms.out as a symlink; the host must replace it, never write through it.
  mkL lsymlink; printf 'intact\n' > "$HOST/victim.txt"; ln -s "$HOST/victim.txt" "$CAN/lsymlink/axioms.out"
  run CL37 canary-audit-output-symlink-not-followed pass - "$CAN/lsymlink" bash -c "$AUDIT; lean_audit \"\$1\" >/dev/null; grep -qx intact \"\$2\" || { echo 'AUDIT output followed a planted symlink'; exit 1; }" _ "$CAN/lsymlink" "$HOST/victim.txt"
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
  run CL35 canary-mutual-recursion-auxiliaries pass - "$CAN/lmutual" bash -euo pipefail -c "$AUDIT; $(declare -f pm_check); lean_audit \"\$1\" >/dev/null; for n in CanaryTree CanaryForest; do grep -q \"^AUDIT checked \$n.brecOn.eq \" axioms.out || { echo \"mutual recursor auxiliary not axiom-checked: \$n\"; exit 1; }; if grep -q \"^AUDIT theorem \$n.brecOn.eq \" axioms.out; then echo \"mutual recursor auxiliary incorrectly requires proof-map row: \$n\"; exit 1; fi; done; grep -q '^AUDIT theorem CanaryTree.brecOn.user_property ' axioms.out || { echo 'user theorem in recursor namespace not inventoried'; exit 1; }; grep -oE '^AUDIT theorem [^ ]+' axioms.out | awk '{print \$3}' > th.txt; if pm_check th.txt \"\$2\" > missing.out 2>&1; then echo 'user theorem incorrectly exempted from proof-map'; exit 1; fi; grep -qx 'unmapped theorem: CanaryTree.brecOn.user_property' missing.out || { cat missing.out; exit 1; }; cp --remove-destination \"\$2\" proof-map.tsv; printf 'CanaryTree.brecOn.user_property\\ttests::adds\\n' >> proof-map.tsv; pm_check th.txt proof-map.tsv" _ "$CAN/lmutual" "$ROOT/proof-map.tsv"
}
fi

# --- T1: threat model. Every threat maps to controls; every gate it names must have PASSed in THIS run;
#     PARTIAL/OPEN must point at a tracking issue (#N). A threat with no control is visible, never silent. ---
threat_check() { # <threat-model.tsv> <results.tsv> <lean mode: run|skip>
  # Controls prefixed "lean:" are required only when the Lean stage ran (REQUIRE_LEAN=0 Rust-only runs skip them).
  local tm="$1" res="$2" mode="${3:-run}"
  [[ "$mode" == run || "$mode" == skip ]] || { echo "THREAT invalid lean mode: $mode"; return 1; }
  [ -f "$tm" ] || { echo "THREAT model missing: $tm"; return 1; }
  local extlist; extlist="$(mktemp)"
  awk -F'\t' -v res="$res" -v mode="$mode" -v extlist="$extlist" '
    BEGIN { while ((getline l < res) > 0) { split(l, f, "\t"); if (f[6]=="PASS") pass[f[1]]=1 } }
    NR==1 { if ($0 != "id\tthreat\tcontrols\tstatus\tnote") { print "THREAT model header invalid"; bad=1 } next }
    /^#/ || !NF { next }
    {
      n++
      if (NF != 5) { print "THREAT row needs 5 columns: " $1; bad=1; next }
      if (seen[$1]++) { print "THREAT duplicate id: " $1; bad=1 }
      st=$4; count[st]++
      if (st !~ /^(COVERED|PARTIAL|OPEN|OUT_OF_SCOPE)$/) { print "THREAT unknown status: " $1 " " st; bad=1 }
      if (st != "OUT_OF_SCOPE" && st != "OPEN" && ($3 == "-" || $3 == "")) { print "THREAT without control: " $1; bad=1 }
      if ((st == "PARTIAL" || st == "OPEN") && $5 !~ /#[0-9]+/) { print "THREAT open without tracking issue: " $1; bad=1 }
      if (st == "OUT_OF_SCOPE" && $5 !~ /[^[:space:]-]/) { print "THREAT out of scope without reason: " $1; bad=1 }
      m = split($3, c, " "); live=0
      for (i = 1; i <= m; i++) {
        g = c[i]; if (g == "-") continue
        if (g ~ /^ext:/) { live++; print g > extlist; continue }   # witnessed below by ext_check, never on its word
        if (g ~ /^lean:/) { g = substr(g, 6); if (mode == "skip") continue }
        live++
        if (!pass[g]) { print "THREAT unknown or failed gate " g " in " $1; bad=1 }
      }
      if (mode == "skip" && (st == "COVERED" || st == "PARTIAL") && !live) print "THREAT not applicable in Rust-only mode: " $1
    }
    END {
      if (!n) { print "THREAT model empty"; bad=1 }
      printf "THREATS total=%d covered=%d partial=%d open=%d out_of_scope=%d\n", n, count["COVERED"], count["PARTIAL"], count["OPEN"], count["OUT_OF_SCOPE"]
      exit bad
    }' "$tm"; local rc=$?
  ext_check "$extlist" || rc=1
  rm -f "$extlist"; return $rc
}
# ext: controls live outside this run (GitHub settings, other workflows). Each one must be witnessed (#45 item 5):
# ext-controls.tsv says how; the ruleset rules come from the GitHub API (EXT_RULES: a JSON file of
# GET /repos/{repo}/rules/branches/{default}, fetched once before T1). Without them EXT_OFFLINE=1 records the
# ruleset-backed controls as unchecked (visible in T1's output and env.txt) instead of failing.
ext_check() { # <file with one ext:name per line>
  "$PY" - "$1" "${EXT_CONTROLS:-}" "${EXT_ROOT:-}" "${EXT_RULES:-}" "${EXT_OFFLINE:-0}" <<'PY'
import json, os, re, sys
names, cfg, root, rules_f, offline = sys.argv[1:6]
want = sorted({l.strip() for l in open(names) if l.strip()})
if not want: sys.exit(0)
bad, rows = [], {}
if not os.path.isfile(cfg): sys.exit(f"THREAT ext controls file missing: {cfg}")
for n, line in enumerate(open(cfg), 1):
    if n == 1 or line.startswith("#") or not line.strip(): continue
    f = line.rstrip("\n").split("\t")
    if len(f) != 5: bad.append(f"THREAT ext controls row needs 5 columns: line {n}"); continue
    rows.setdefault(f[0], []).append(f[1:4])
rules = None
if rules_f and os.path.isfile(rules_f):
    try: rules = json.load(open(rules_f))
    except Exception as e: bad.append(f"THREAT ext ruleset rules unreadable: {e}")
def wf_files(d):
    return [os.path.join(d, x) for x in sorted(os.listdir(d)) if x.endswith((".yml", ".yaml"))]
def scalar(v):  # a plain or quoted YAML scalar on one line, trailing comment removed
    v = v.strip()
    if v[:1] in "'\"":
        q = v[0]; e = v.find(q, 1); return v[1:e] if e > 0 else None
    return re.sub(r"\s+#.*$", "", v).strip()
def producers():
    # contexts a workflow can produce: a job's name (or its id when it has none) and explicit status publishers
    # (context=<x>). Only block-style job mappings are read; anything else produces nothing (fails safe).
    out = set()
    for f in wf_files(os.path.join(root, ".github/workflows")):
        lines = open(f, errors="replace").read().splitlines(); jobs = None; job = None; named = False
        for l in lines + ["end:"]:
            if re.match(r"^jobs:\s*(#.*)?$", l): jobs = 0; continue
            if jobs is None: continue
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", l)
            if (m or re.match(r"^\S", l)) and job is not None and not named: out.add(job)
            if re.match(r"^\S", l): jobs = None; job = None; continue
            if m: job, named = m.group(1), False; continue
            n = re.match(r"^    name:\s*(.+)$", l)
            if n and job is not None:
                v = scalar(n.group(1))
                if v: out.add(v); named = True
        for m in re.finditer(r"\bcontext=([A-Za-z0-9_.-]+)", "\n".join(lines)): out.add(m.group(1))
    return out
unchecked, ok = [], 0
for g in want:
    if g not in rows: bad.append(f"THREAT unknown ext control {g} (not in ext-controls.tsv)"); continue
    for kind, target, pat in rows[g]:
        why = None
        if kind in ("required-check", "rule"):
            if rules is None:
                if offline == "1": unchecked.append(g); continue
                why = "ruleset rules unavailable (EXT_RULES unset or fetch failed; EXT_OFFLINE=1 to record as unchecked)"
            elif kind == "rule":
                if not any(r.get("type") == target for r in rules): why = f"no active rule {target} on the default branch"
            else:
                ctx = {c.get("context") for r in rules if r.get("type") == "required_status_checks"
                       for c in (r.get("parameters") or {}).get("required_status_checks", [])}
                if target not in ctx: why = f"'{target}' is not a required status check on the default branch"
                elif target not in producers(): why = f"no workflow job or status publisher produces '{target}'"
        elif kind == "file":
            p = os.path.join(root, target)
            if not os.path.isfile(p): why = f"{target} missing"
            elif not any(re.search(pat, l) for l in open(p, errors="replace")): why = f"{target} has no line matching {pat}"
        elif kind == "pinned-actions":
            d = os.path.join(root, target); loose = []
            for f in wf_files(d):
                for n, l in enumerate(open(f, errors="replace"), 1):
                    # block, flow ({ uses: x }) and quoted forms; a block scalar or escaped key is refused (fails safe)
                    if re.search(r"[\"'][^\"']*\\[xuU][^\"']*[\"']\s*:", l):
                        loose.append(f"{os.path.basename(f)}:{n} escaped key"); continue
                    for m in re.finditer(r"(?:^|[\s{,\-])[\"']?uses[\"']?\s*:\s*(.*)", l):
                        raw = re.split(r"[,}]", m.group(1))[0]; v = scalar(raw) if raw.strip() else ""
                        if not v or v in ("|", ">", "|-", ">-", "|+", ">+"):
                            loose.append(f"{os.path.basename(f)}:{n} unreadable uses value"); continue
                        if not (v.startswith(("./", "$/")) or re.search(r"@[0-9a-f]{40}$", v)):
                            loose.append(f"{os.path.basename(f)}:{n} {v}")
            if loose: why = "not SHA-pinned: " + ", ".join(loose[:3])
        else:
            why = f"unknown kind {kind}"
        if why: bad.append(f"THREAT ext control not in force: {g}: {why}")
        else: ok += 1
for g in sorted(set(unchecked)): print(f"THREAT ext unchecked (offline): {g}")
print(f"THREAT ext controls witnessed={ok} unchecked={len(set(unchecked))} failed={len(bad)}")
for b in bad: print(b)
sys.exit(1 if bad else 0)
PY
}
TM_DIR="$ROOT"; while [ "$TM_DIR" != / ] && [ ! -f "$TM_DIR/threat-model.tsv" ]; do TM_DIR="$(dirname "$TM_DIR")"; done
export EXT_CONTROLS="${EXT_CONTROLS:-${TM_DIR%/}/ext-controls.tsv}" EXT_ROOT="${EXT_ROOT:-${TM_DIR%/}}"
if [ -z "${EXT_RULES:-}" ] && [ "${EXT_OFFLINE:-0}" != 1 ]; then
  # the repository: GITHUB_REPOSITORY in CI, else the origin remote; anonymous read works for public repositories
  EXT_REPO="${GITHUB_REPOSITORY:-$(git -C "$EXT_ROOT" remote get-url origin 2>/dev/null | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')}"
  if [ -n "$EXT_REPO" ] && "$PY" - "$EXT_REPO" "$WORK/ext-rules.json" <<'PY' 2>"$WORK/ext-rules.err"; then export EXT_RULES="$WORK/ext-rules.json"; fi
import json, os, sys, urllib.request
repo, out = sys.argv[1], sys.argv[2]
tok = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
def get(u):
    r = urllib.request.Request("https://api.github.com/" + u, headers={"Accept": "application/vnd.github+json", **({"Authorization": "Bearer " + tok} if tok else {})})
    return json.load(urllib.request.urlopen(r, timeout=20))
branch = get(f"repos/{repo}")["default_branch"]
json.dump(get(f"repos/{repo}/rules/branches/{branch}"), open(out, "w"))
PY
fi
# canaries run on copies, never on the real model; T1 must not name itself as a control
mkdir -p "$CAN/threat"
{ head -1 "${TM_DIR%/}/threat-model.tsv"; printf 'X-1\tcanary\tS9z\tCOVERED\tgate does not exist\n'; } > "$CAN/threat/unknown.tsv"
run C11 canary-threat-unknown-gate fail '^THREAT unknown or failed gate S9z' "$ROOT" threat_check "$CAN/threat/unknown.tsv" "$RES" run
{ head -1 "${TM_DIR%/}/threat-model.tsv"; printf 'X-2\tcanary\tS0a\tOPEN\tno issue reference\n'; } > "$CAN/threat/untracked.tsv"
run C12 canary-threat-open-untracked fail '^THREAT open without tracking issue: X-2' "$ROOT" threat_check "$CAN/threat/untracked.tsv" "$RES" run
# C13: a Lean gate WITHOUT the lean: prefix is still required in Rust-only mode (the prefix is the only way out)
{ head -1 "${TM_DIR%/}/threat-model.tsv"; printf 'X-3\tcanary\tS0a L2x\tCOVERED\tunprefixed Lean-style gate\n'; } > "$CAN/threat/unprefixed.tsv"
run C13 canary-threat-unprefixed-lean-gate fail '^THREAT unknown or failed gate L2x' "$ROOT" threat_check "$CAN/threat/unprefixed.tsv" "$RES" skip
# C55-C60: ext: controls are witnessed, not counted on their word (#45 item 5). Self-contained fixtures: a rules file,
# an ext-controls file and a repository root of their own, so the canaries need no network.
TX="$CAN/threat/ext"; mkdir -p "$TX/root/.github/workflows"
printf '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"core (S0-S2 + canaries)"}]}}]\n' > "$TX/rules.json"
printf 'name: x\njobs:\n  core:\n    name: core (S0-S2 + canaries)\n    steps:\n      - uses: actions/checkout@v4\n' > "$TX/root/.github/workflows/x.yml"
printf 'ext\tkind\ttarget\tpattern\tnote\next:req\trequired-check\tnot a required check\t\t\next:nff\trule\tnon_fast_forward\t\t\next:file\tfile\t.github/workflows/x.yml\tno-such-line\t\next:pin\tpinned-actions\t.github/workflows\t\t\next:del\trule\tdeletion\t\t\n' > "$TX/ext.tsv"
for c in no-such-control req nff file pin del; do { head -1 "${TM_DIR%/}/threat-model.tsv"; printf 'X-%s\tcanary\text:%s\tCOVERED\tfixture\n' "$c" "$c"; } > "$TX/$c.tsv"; done
EXT_CONTROLS="$TX/ext.tsv" EXT_ROOT="$TX/root" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C55 canary-threat-unknown-ext fail '^THREAT unknown ext control ext:no-such-control' "$ROOT" threat_check "$TX/no-such-control.tsv" "$RES" run
EXT_CONTROLS="$TX/ext.tsv" EXT_ROOT="$TX/root" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C56 canary-threat-ext-not-required fail "^THREAT ext control not in force: ext:req: 'not a required check' is not a required status check" "$ROOT" threat_check "$TX/req.tsv" "$RES" run
EXT_CONTROLS="$TX/ext.tsv" EXT_ROOT="$TX/root" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C57 canary-threat-ext-rule-missing fail '^THREAT ext control not in force: ext:nff: no active rule non_fast_forward' "$ROOT" threat_check "$TX/nff.tsv" "$RES" run
EXT_CONTROLS="$TX/ext.tsv" EXT_ROOT="$TX/root" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C58 canary-threat-ext-file-unwired fail '^THREAT ext control not in force: ext:file: .* has no line matching no-such-line' "$ROOT" threat_check "$TX/file.tsv" "$RES" run
EXT_CONTROLS="$TX/ext.tsv" EXT_ROOT="$TX/root" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C59 canary-threat-ext-unpinned-action fail '^THREAT ext control not in force: ext:pin: not SHA-pinned: x.yml:6 actions/checkout@v4' "$ROOT" threat_check "$TX/pin.tsv" "$RES" run
EXT_CONTROLS="$TX/ext.tsv" EXT_ROOT="$TX/root" EXT_RULES= EXT_OFFLINE=0 run C60 canary-threat-ext-rules-unavailable fail '^THREAT ext control not in force: ext:del: ruleset rules unavailable' "$ROOT" threat_check "$TX/del.tsv" "$RES" run
# C61/C62 (Codex on #51): the required context only in a comment of a renamed job produces nothing; a flow-style step
# ({ uses: x@v4 }) is still an unpinned action
mkdir -p "$TX/root2/.github/workflows"
printf 'name: y\njobs:\n  a:\n    name: renamed # core (S0-S2 + canaries)\n    steps:\n      - { uses: actions/checkout@v4 }\n' > "$TX/root2/.github/workflows/y.yml"
printf 'ext\tkind\ttarget\tpattern\tnote\next:core\trequired-check\tcore (S0-S2 + canaries)\t\t\next:flow\tpinned-actions\t.github/workflows\t\t\n' > "$TX/ext2.tsv"
for c in core flow; do { head -1 "${TM_DIR%/}/threat-model.tsv"; printf 'X-%s\tcanary\text:%s\tCOVERED\tfixture\n' "$c" "$c"; } > "$TX/$c.tsv"; done
EXT_CONTROLS="$TX/ext2.tsv" EXT_ROOT="$TX/root2" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C61 canary-threat-ext-context-only-in-comment fail "^THREAT ext control not in force: ext:core: no workflow job or status publisher produces 'core \(S0-S2 \+ canaries\)'" "$ROOT" threat_check "$TX/core.tsv" "$RES" run
EXT_CONTROLS="$TX/ext2.tsv" EXT_ROOT="$TX/root2" EXT_RULES="$TX/rules.json" EXT_OFFLINE=0 run C62 canary-threat-ext-flow-style-unpinned fail '^THREAT ext control not in force: ext:flow: not SHA-pinned: y.yml:6 actions/checkout@v4' "$ROOT" threat_check "$TX/flow.tsv" "$RES" run
# --- R1/C14-C16: approved release source (SLSA-D). The same script release.yml runs before publishing. ---
RSC="$SD/release-source-check.sh"
[ -f "$RSC" ] || echo "RELEASE helper missing next to ci-local.sh: $RSC (gates R1/C14-C16 will FAIL)" >&2
gitc() { git -c user.name=canary -c user.email=canary@invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
G="$CAN/relsrc"; rm -rf "$G"; mkdir -p "$G"
( cd "$G" && gitc init -q -b main && gitc commit -q --allow-empty -m base && gitc tag v1.2.3 && gitc tag vbad \
  && gitc checkout -q -b side && gitc commit -q --allow-empty -m side && gitc tag v9.9.9 && gitc checkout -q main ) > /dev/null 2>&1
MAIN_SHA=$(git -C "$G" rev-parse main); SIDE_SHA=$(git -C "$G" rev-parse side)
run R1 release-source-approved pass - "$G" bash "$RSC" refs/tags/v1.2.3 "$MAIN_SHA" main
run C14 canary-release-off-main fail '^RELEASE source not approved' "$G" bash "$RSC" refs/tags/v9.9.9 "$SIDE_SHA" main
run C15 canary-release-bad-ref fail '^RELEASE ref not approved' "$G" bash "$RSC" refs/tags/vbad "$MAIN_SHA" main
run C16 canary-release-tag-mismatch fail '^RELEASE tag does not point at built commit' "$G" bash "$RSC" refs/tags/v1.2.3 "$SIDE_SHA" main
# --- E1/C17-C19: signed gate evidence (CI-4). Same scripts the attest job and release.yml run. ---
EPS="$SD/evidence-predicate.sh"; EVD="$SD/evidence-verdict.sh"
for h in "$EPS" "$EVD"; do [ -f "$h" ] || echo "EVIDENCE helper missing next to ci-local.sh: $h (gates E1/C17-C19 will FAIL)" >&2; done
mkev() { # <dir> <verdict of the second gate row>
  mkdir -p "$1"
  printf 'id\tstep\texpect\texit\treason_check\tverdict\nG1\tg\tpass\t0\tn/a\tPASS\nG2\tg\tpass\t0\tn/a\t%s\n' "$2" > "$1/results.tsv"
  ( cd "$1" && sha256sum results.tsv > SHA256SUMS )
}
mkev "$CAN/ev-ok" PASS; mkev "$CAN/ev-fail" FAIL; mkev "$CAN/ev-tamper" PASS
printf 'G3\tg\tpass\t0\tn/a\tPASS\n' >> "$CAN/ev-tamper/results.tsv"
verdict_of() { local p; p=$(bash "$EPS" "$1" https://example.invalid/run) || return 1; bash "$EVD" "$(printf '%s' "$p" | sed -n 's/^{"result":"\([A-Z]*\)".*/\1/p')"; }
run E1 evidence-predicate-pass pass - "$ROOT" verdict_of "$CAN/ev-ok"
# E2/C72/C73: two sealed runs of the same commit compared gate by gate (scripts/evidence-compare.sh, gap G8)
EC="$ROOT/scripts/evidence-compare.sh"; EX="$CAN/evcmp"; mkdir -p "$EX/a" "$EX/b" "$EX/c" "$EX/d"
for d in a b c d; do
  printf 'git_head=0123abcd\n' > "$EX/$d/env.txt"
  printf 'id\tstep\texpect\texit\treason_check\tverdict\nS1a\tfmt\tpass\t0\tn/a\tPASS\nC1\tcanary-fmt\tfail\t1\tmatched\tPASS\n' > "$EX/$d/results.tsv"
  printf 'S1a\taa bb\nC1\taa bb cc\n' > "$EX/$d/signatures.tsv"
done
sed -i 's/matched\tPASS$/unmatched\tFAIL_WRONG_REASON/' "$EX/c/results.tsv"
for d in a b c d; do ( cd "$EX/$d" && sha256sum env.txt results.tsv signatures.tsv > SHA256SUMS ); done
printf 'tampered\n' >> "$EX/d/results.tsv"
mkdir -p "$EX/e" && cp "$EX/a/"* "$EX/e/" && ( cd "$EX/e" && sha256sum env.txt > SHA256SUMS )   # seal leaves results.tsv out
run E2 evidence-compare-match pass - "$ROOT" bash "$EC" compare "$EX/a" "$EX/b"
run C72 canary-evidence-compare-verdict-differs fail '^EVIDENCE verdict differs C1: PASS vs FAIL_WRONG_REASON' "$ROOT" bash "$EC" compare "$EX/a" "$EX/c"
run C73 canary-evidence-compare-seal-broken fail '^EVIDENCE seal broken' "$ROOT" bash "$EC" compare "$EX/a" "$EX/d"
run C75 canary-evidence-compare-partial-seal fail '^EVIDENCE not sealed: .*does not cover results.tsv' "$ROOT" bash "$EC" compare "$EX/a" "$EX/e"
run C17 canary-evidence-failed-gate fail '^EVIDENCE result not PASSED: FAILED' "$ROOT" verdict_of "$CAN/ev-fail"
run C18 canary-evidence-tampered fail '^EVIDENCE checksum mismatch' "$ROOT" verdict_of "$CAN/ev-tamper"
run C19 canary-evidence-no-attestation fail '^EVIDENCE no attestation' "$ROOT" bash "$EVD" ""
# --- A1/A2/C20-C25: agent PR policy (CI-7). Same script the agent-pr-policy workflow runs (from main). ---
APP="$SD/agent-pr-policy.sh"
[ -f "$APP" ] || echo "AGENT helper missing next to ci-local.sh: $APP (gates A1/A2/C20-C25 will FAIL)" >&2
mkpr() { # <dir> <branch> <commits> <files> <label events> <labels now> <codex rows>; last push 2026-01-01T00:00:00Z
  mkdir -p "$1"; printf '%s\n' "$2" > "$1/branch.txt"; printf 'h1\n' > "$1/head_sha.txt"
  printf '2026-01-01T00:00:00Z\n' > "$1/pushed_at.txt"
  printf '%b' "$3" > "$1/commits.tsv"; printf '%b' "$4" > "$1/files.txt"; printf '%b' "$5" > "$1/labels.tsv"
  printf '%b' "$6" > "$1/labels_now.txt"; printf '%b' "$7" > "$1/codex.tsv"; printf 'owner\n' > "$1/owners.txt"
}
LBL='owner-approved-pipeline\n'
OWN='owner-approved-pipeline\towner\tUser\t2026-01-02T00:00:00Z\n'
CDX='h1\tcompleted\tfalse\tchatgpt-codex-connector[bot]\tBot\n'
# a human-looking PR (no agent marker) gets no bypass: owner label for the pipeline and a clean Codex review (#45 item 6)
mkpr "$CAN/pr-human" feat/x 'owner\tweb-flow\t0\th1\n' '.github/workflows/ci.yml\nsrc/lib.rs\n' "$OWN" "$LBL" "$CDX"
mkpr "$CAN/pr-human-nolabel" feat/x 'owner\tweb-flow\t0\th1\n' '.github/workflows/ci.yml\n' '' '' "$CDX"
mkpr "$CAN/pr-human-nocodex" feat/x 'owner\tweb-flow\t0\th1\n' 'src/lib.rs\n' '' '' ''
mkpr "$CAN/pr-agent-ok" copilot/x 'Copilot\towner\t0\th1\n' 'scripts/ci-local.sh\n' "$OWN" "$LBL" "$CDX"
mkpr "$CAN/pr-agent-nolabel" feat/y 'owner\tweb-flow\t1\th1\n' 'scripts/ci-local.sh\n' '' '' "$CDX"
mkpr "$CAN/pr-agent-botlabel" copilot/x 'Copilot\towner\t0\th1\n' '.github/workflows/ci.yml\n' 'owner-approved-pipeline\tsome-app[bot]\tBot\t2026-01-02T00:00:00Z\n' "$LBL" "$CDX"
mkpr "$CAN/pr-agent-stale-codex" codex/x 'owner\towner\t0\th1\n' 'src/lib.rs\n' '' '' 'h0\tcompleted\tfalse\tchatgpt-codex-connector[bot]\tBot\n'
mkpr "$CAN/pr-agent-findings" claude/x 'owner\towner\t1\th1\n' 'src/lib.rs\n' '' '' 'h1\tcompleted\ttrue\tchatgpt-codex-connector[bot]\tBot\n'
mkpr "$CAN/pr-agent-stale-label" copilot/x 'Copilot\towner\t0\th1\n' 'scripts/ci-local.sh\n' 'owner-approved-pipeline\towner\tUser\t2025-12-31T00:00:00Z\n' "$LBL" "$CDX"
mkpr "$CAN/pr-agent-spoofed-codex" claude/x 'owner\towner\t1\th1\n' 'src/lib.rs\n' '' '' 'h1\tcompleted\ttrue\tchatgpt-codex-connector[bot]\tBot\nh1\tcompleted\tfalse\tnot-the-codex-reviewer\tUser\n'
# config-only change: gate configuration (Kani, cargo, nextest) is pipeline too
mkpr "$CAN/pr-agent-config-only" copilot/x 'Copilot\towner\t0\th1\n' 'kani-harnesses.tsv\n.cargo/config.toml\nclaims.tsv\nspec-paths.txt\n' '' '' "$CDX"
run A1 agent-policy-human-pass pass - "$ROOT" bash "$APP" "$CAN/pr-human"
run A2 agent-policy-approved-agent-pass pass - "$ROOT" bash "$APP" "$CAN/pr-agent-ok"
run C20 canary-agent-pipeline-no-label fail '^AGENT PR touches pipeline without owner label \(no label\)' "$ROOT" bash "$APP" "$CAN/pr-agent-nolabel"
run C21 canary-agent-label-by-bot fail '^AGENT PR touches pipeline without owner label \(label not applied by a human owner\)' "$ROOT" bash "$APP" "$CAN/pr-agent-botlabel"
run C22 canary-agent-codex-not-on-head fail '^AGENT PR head not reviewed by Codex: h1' "$ROOT" bash "$APP" "$CAN/pr-agent-stale-codex"
run C23 canary-agent-unresolved-findings fail '^AGENT PR has unresolved Codex findings' "$ROOT" bash "$APP" "$CAN/pr-agent-findings"
run C24 canary-agent-label-before-push fail '^AGENT PR touches pipeline without owner label \(label predates the latest push' "$ROOT" bash "$APP" "$CAN/pr-agent-stale-label"
run C25 canary-agent-spoofed-codex fail '^AGENT PR has unresolved Codex findings' "$ROOT" bash "$APP" "$CAN/pr-agent-spoofed-codex"
run C63 canary-unmarked-pipeline-no-label fail '^AGENT PR touches pipeline without owner label \(no label\)' "$ROOT" bash "$APP" "$CAN/pr-human-nolabel"
run C64 canary-unmarked-no-codex fail '^AGENT PR head not reviewed by Codex: h1' "$ROOT" bash "$APP" "$CAN/pr-human-nocodex"
run C27 canary-agent-config-only-no-label fail '^AGENT PR touches pipeline without owner label \(no label\)' "$ROOT" bash "$APP" "$CAN/pr-agent-config-only"
# --- T2: the registries agree with each other (#G13): every canary that ran is relied on by a threat row or an
# assumption (an orphan canary guards nothing anyone claims), every ext-controls row is named by a threat row,
# every assumption belongs to a claim, every claim has an assumption row. C69-C71 plant each kind of drift.
registry_check() { # <threat-model.tsv> <results.tsv> <assumptions.tsv> <claims.tsv> <ext-controls.tsv>
  "$PY" - "$@" <<'PY'
import sys
tm, res, asm, claims, ext = sys.argv[1:6]
rows = lambda f: [l.rstrip("\n").split("\t") for l in open(f) if l.strip() and not l.startswith("#")]
named = set()
for r in rows(tm)[1:]:
    if len(r) >= 3: named |= {c.split(":", 1)[1] if c.startswith("lean:") else c for c in r[2].split()}
breakers = set()
a_rows = rows(asm)
for r in a_rows:
    if len(r) >= 4 and r[3].startswith("gate:"): breakers.add(r[3][5:].split("@")[0])
canaries = [r[0] for r in rows(res)[1:] if len(r) >= 3 and r[2] == "fail"]
bad = [f"REGISTRY orphan canary {c}: no threat row or assumption relies on it" for c in canaries if c not in named | breakers]
ext_names = {r[0] for r in rows(ext)[1:] if r and r[0].startswith("ext:")}
bad += [f"REGISTRY stale ext control {e}: no threat row names it" for e in sorted(ext_names - named)]
claim_ids = {r[0] for r in rows(claims) if r}
asm_claims = {r[0] for r in a_rows if r}
bad += [f"REGISTRY assumption for unknown claim {c}" for c in sorted(asm_claims - claim_ids)]
bad += [f"REGISTRY claim {c} has no assumption row" for c in sorted(claim_ids - asm_claims)]
print(f"REGISTRY {len(canaries)} canaries, {len(ext_names)} ext controls, {len(claim_ids)} claims checked")
for b in bad: print(b)
sys.exit(1 if bad else 0)
PY
}
RG="$CAN/registry"; mkdir -p "$RG"
head -1 "$RES" > "$RG/res.tsv"; printf 'C9z\tcanary-unrelied\tfail\t1\tmatched\tPASS\n' >> "$RG/res.tsv"
{ cat "${TM_DIR%/}/ext-controls.tsv"; printf 'ext:nobody-names-me\tfile\tREADME.md\tx\t\n'; } > "$RG/ext.tsv"
{ cat "${TM_DIR%/}/assumptions.tsv"; printf 'CA9\tA1\tx\ttrusted:canary\n'; } > "$RG/asm.tsv"
run C69 canary-registry-orphan-canary fail '^REGISTRY orphan canary C9z' "$ROOT" registry_check "${TM_DIR%/}/threat-model.tsv" "$RG/res.tsv" "${TM_DIR%/}/assumptions.tsv" "${TM_DIR%/}/claims.tsv" "${TM_DIR%/}/ext-controls.tsv"
run C70 canary-registry-stale-ext fail '^REGISTRY stale ext control ext:nobody-names-me' "$ROOT" registry_check "${TM_DIR%/}/threat-model.tsv" "$RES" "${TM_DIR%/}/assumptions.tsv" "${TM_DIR%/}/claims.tsv" "$RG/ext.tsv"
run C71 canary-registry-assumption-unknown-claim fail '^REGISTRY assumption for unknown claim CA9' "$ROOT" registry_check "${TM_DIR%/}/threat-model.tsv" "$RES" "$RG/asm.tsv" "${TM_DIR%/}/claims.tsv" "${TM_DIR%/}/ext-controls.tsv"
run T2 registries-consistent pass - "$ROOT" registry_check "${TM_DIR%/}/threat-model.tsv" "$RES" "${TM_DIR%/}/assumptions.tsv" "${TM_DIR%/}/claims.tsv" "${TM_DIR%/}/ext-controls.tsv"
run T1 threat-model pass - "$ROOT" threat_check "${TM_DIR%/}/threat-model.tsv" "$RES" "$LMODE"
echo "ext_rules=${EXT_RULES:-none} | ext_offline=${EXT_OFFLINE:-0}" >> "$EV/env.txt"

# --- summary ---
TOTAL=$(($(wc -l < "$RES") - 1)); OK=$(grep -c $'\tPASS$' "$RES" || true)
echo "PROGRESS=$OK/$TOTAL" | tee "$EV/summary.txt"
echo "evidence=$EV" | tee -a "$EV/summary.txt"
echo "build_dir=$WORK (outside repo, temporary)" | tee -a "$EV/summary.txt"
if [ "$LMODE" = skip ]; then
  seal_evidence "$EV" S0a S0b S0s S0f S1a S1b S1e S1f S1g S1i S1c S1d S1h S2a S2b S2c C{1..75} R1 E1 E2 A1 A2 CL29 CL30 CL32 LSKIP T2 T1
else
  seal_evidence "$EV" S0a S0b S0s S0f S1a S1b S1e S1f S1g S1i S1c S1d S1h S2a S2b S2c C{1..75} R1 E1 E2 A1 A2 T2 T1 CL{29..32} L00 L0 L0b L1 L2 L3 L4 X1 X2 CL{1..28} CL{33..39}
fi
