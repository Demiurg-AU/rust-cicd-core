#!/usr/bin/env bash
# sandbox.sh - source me. Runs code under test (build scripts, proc macros, tests, Lean elaboration)
# so that it cannot rewrite the evidence that judges it (threat CI-9 / ROADMAP O1).
#
#   sandbox <cmd...>   run <cmd> in a bubblewrap jail:
#       read-only : the whole filesystem (repo, evidence, scripts, .git, ~/.cargo/config + bin,
#                   toolchains, $RUNNER_TEMP with GITHUB_ENV/GITHUB_OUTPUT files)
#       writable  : a fresh private TMPDIR (removed afterwards), $CARGO_TARGET_DIR, the current directory when it is under
#                   the run's work dir ($SANDBOX_WORK), every path in $SANDBOX_RW (":"-separated),
#                   and ~/.cargo/registry + ~/.cargo/git (dependency downloads)
#       no PID sharing with the caller (cannot signal/ptrace the runner); every process it spawns
#       dies with it; no controlling terminal; Actions credentials and command files removed from env.
#   sandbox_cargo / sandbox_elan   wrappers installed as shell functions named cargo / elan by
#       sandbox_enable: code-executing subcommands are jailed, read-only ones (fmt, deny, audit,
#       --version) run directly - they execute no project code and need their own caches.
#
# There is no "off" switch: if bubblewrap is missing the jailed commands fail (gate S0s says why).
SANDBOX_BWRAP="${SANDBOX_BWRAP:-bwrap}"

sandbox() {
  local args=(--ro-bind / / --dev /dev --proc /proc
              --unshare-pid --die-with-parent --new-session)
  local p cwd tmp rc; cwd="$(pwd -P)"
  tmp="$(mktemp -d "${SANDBOX_WORK:-${TMPDIR:-/tmp}}/sbx-tmp.XXXXXX")" || { echo "SANDBOX no temp dir"; return 125; }
  local rw=("$tmp")
  [ -n "${CARGO_TARGET_DIR:-}" ] && { mkdir -p "$CARGO_TARGET_DIR"; rw+=("$CARGO_TARGET_DIR"); }
  if [ -n "${SANDBOX_WORK:-}" ] && [[ "$cwd/" == "$SANDBOX_WORK/"* ]]; then rw+=("$cwd"); fi
  if [ -n "${SANDBOX_RW:-}" ]; then IFS=: read -ra p <<< "$SANDBOX_RW"; rw+=("${p[@]}"); fi
  local ch="${CARGO_HOME:-$HOME/.cargo}"
  for p in "$ch/registry" "$ch/git"; do mkdir -p "$p" 2>/dev/null && rw+=("$p"); done
  for p in "${rw[@]}"; do [ -n "$p" ] && [ -e "$p" ] && args+=(--bind "$p" "$p"); done
  for p in GITHUB_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL \
           ACTIONS_CACHE_URL ACTIONS_RESULTS_URL GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STATE GITHUB_STEP_SUMMARY; do
    args+=(--unsetenv "$p")
  done
  args+=(--setenv TMPDIR "$tmp" --chdir "$cwd")
  "$SANDBOX_BWRAP" "${args[@]}" -- "$@"; rc=$?
  rm -rf "$tmp"; return "$rc"
}

sandbox_cargo() {
  local sub="${1:-}" a
  # first non-option argument is the subcommand (cargo +toolchain / -q forms)
  for a in "$@"; do case "$a" in +*|-*) ;; *) sub="$a"; break ;; esac; done
  case "$sub" in
    fmt|deny|audit|metadata|--version|-V|version|"") command cargo "$@" ;;
    *) sandbox cargo "$@" ;;   # build, test, clippy, nextest, llvm-cov, mutants, kani, run, ...
  esac
}
sandbox_elan() { sandbox elan "$@"; }

sandbox_enable() { # turn bare `cargo` and `elan` into jailed calls, also inside `bash -c` children
  cargo() { sandbox_cargo "$@"; }
  elan() { sandbox_elan "$@"; }
  export -f sandbox sandbox_cargo sandbox_elan cargo elan
  export SANDBOX_BWRAP
}

# probe: try to write every protected path; succeed (exit 0) only if a write got through.
# A gate runs it expecting failure with "SANDBOX all writes blocked".
sandbox_probe() { # <path>...
  local p n=0 bad=""
  for p in "$@"; do
    n=$((n + 1))
    # a path that does not exist yet is protected by its directory: probe that instead (creates nothing)
    [ -e "$p" ] || p="$(dirname "$p")"
    if [ -d "$p" ]; then
      if sandbox bash -c 't="$1/.sandbox-probe.$$"; : > "$t" && rm -f "$t"' _ "$p" 2>/dev/null; then bad="$bad $p"; fi
    elif sandbox bash -c ': >> "$1"' _ "$p" 2>/dev/null; then bad="$bad $p"; fi
  done
  if [ -n "$bad" ]; then echo "SANDBOX write SUCCEEDED:$bad"; return 0; fi
  echo "SANDBOX all writes blocked ($n paths)"; return 1
}
