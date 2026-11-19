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
#       no network namespace shared (no TCP/UDP, no abstract unix sockets) and an empty /run (no docker.sock,
#       dbus, systemd sockets): a read-only bind does NOT stop connect() to a unix socket, and the runner
#       user's docker socket would be a full escape. Dependencies are fetched beforehand (cargo fetch).
#       no PID sharing with the caller (cannot signal/ptrace the runner); every process it spawns
#       dies with it; no controlling terminal; Actions credentials and command files removed from env.
#   sandbox_cargo / sandbox_elan   wrappers installed as shell functions named cargo / elan by
#       sandbox_enable: code-executing subcommands are jailed, read-only ones (fmt, deny, audit,
#       --version) run directly - they execute no project code and need their own caches.
#
# There is no "off" switch: if bubblewrap is missing the jailed commands fail (gate S0s says why).
SANDBOX_BWRAP="${SANDBOX_BWRAP:-bwrap}"

sandbox() {
  local p a cwd tmp rc s; cwd="$(pwd -P)"
  local args=(--ro-bind / / --dev /dev --proc /proc
              --unshare-pid --unshare-net --unshare-ipc --die-with-parent --new-session
              --setenv CARGO_NET_OFFLINE true)
  # unix sockets: an empty /run and /tmp hide docker.sock, dbus, systemd and stray /tmp sockets; any other socket
  # found by sandbox_enable is masked with /dev/null. The run's own WORK stays visible (read-only).
  [ -d /run ] && args+=(--tmpfs /run)
  args+=(--tmpfs /tmp)
  if [ -n "${SANDBOX_WORK:-}" ]; then args+=(--ro-bind "$SANDBOX_WORK" "$SANDBOX_WORK"); fi
  # the directory the command runs in must stay visible (read-only unless granted below), also under /tmp
  case "$cwd" in /tmp|/tmp/*) args+=(--ro-bind "$cwd" "$cwd") ;; esac
  while IFS= read -r s; do [ -n "$s" ] && [ -S "$s" ] && args+=(--ro-bind /dev/null "$s"); done <<< "${SANDBOX_SOCKS:-}"
  tmp="$(mktemp -d "${SANDBOX_WORK:-${TMPDIR:-/tmp}}/sbx-tmp.XXXXXX")" || { echo "SANDBOX no temp dir"; return 125; }
  local rw=("$tmp")
  [ -n "${CARGO_TARGET_DIR:-}" ] && { mkdir -p "$CARGO_TARGET_DIR"; rw+=("$CARGO_TARGET_DIR"); }
  if [ -n "${SANDBOX_WORK:-}" ] && [[ "$cwd/" == "$SANDBOX_WORK/"* ]]; then rw+=("$cwd"); fi
  if [ -n "${SANDBOX_RW:-}" ]; then
    IFS=: read -ra p <<< "$SANDBOX_RW"
    # an explicit writable path that does not exist is a caller bug: fail loudly instead of a silent read-only run
    for a in "${p[@]}"; do [ -e "$a" ] || { echo "SANDBOX writable path missing: $a (cwd $cwd)" >&2; return 125; }; done
    rw+=("${p[@]}")
  fi
  local ch="${CARGO_HOME:-$HOME/.cargo}"
  for p in "$ch/registry" "$ch/git"; do mkdir -p "$p" 2>/dev/null && rw+=("$p"); done
  for p in "${rw[@]}"; do [ -n "$p" ] && [ -e "$p" ] && { p="$(realpath -- "$p")"; args+=(--bind "$p" "$p"); }; done
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
    # read-only or download-only subcommands: no project code runs (fetch downloads, it does not build)
    fmt|deny|audit|metadata|fetch|--version|-V|version|"") command cargo "$@" ;;
    *) sandbox cargo "$@" ;;   # build, test, clippy, nextest, llvm-cov, mutants, kani, run, ...
  esac
}
sandbox_elan() { sandbox elan "$@"; }

jail_armed() { # are bare cargo/elan still the jail wrappers? (a test mock or `unset -f` would disarm them)
  [[ "$(declare -f cargo 2>/dev/null)" == *sandbox_cargo* && "$(declare -f elan 2>/dev/null)" == *sandbox_elan* ]]
}

sandbox_sockets() { # every unix socket outside /proc /sys /dev /run /tmp (those are hidden by tmpfs anyway);
  # /usr /opt /snap skipped for speed - the C31 probe searches everything and fails if one is reachable
  find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /usr -o -path /opt -o -path /snap \) -prune \
       -o -type s -print 2>/dev/null || true   # unreadable dirs make find exit 1; callers may run under set -e
}

sandbox_enable() { # turn bare `cargo` and `elan` into jailed calls, also inside `bash -c` children
  [ -n "${SANDBOX_SOCKS+x}" ] || SANDBOX_SOCKS="$(sandbox_sockets)"
  export SANDBOX_SOCKS
  cargo() { sandbox_cargo "$@"; }
  elan() { sandbox_elan "$@"; }
  export -f sandbox sandbox_cargo sandbox_elan cargo elan jail_armed
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

# probe: can jailed code reach a host unix socket or the network? Host side lists every socket it can see
# (plus one it opens itself, so the probe is meaningful on any machine); succeed (exit 0) if any is reachable.
sandbox_probe_sockets() { # <dir for the decoy socket: outside SANDBOX_WORK, e.g. a fresh mktemp -d in /tmp>
  local dir="$1" decoy socks out
  decoy="$dir/decoy.sock"; rm -f "$decoy"
  python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); time.sleep(120)' "$decoy" &
  local spid=$!; local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$decoy" ] && break; sleep 0.2; done
  socks="$( { echo "$decoy"; find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type s -print 2>/dev/null || true; } | sort -u )"
  out="$(printf '%s\n' "$socks" | sandbox python3 -c '
import socket, sys
reached = []
for p in filter(None, sys.stdin.read().split("\n")):
    c = socket.socket(socket.AF_UNIX); c.settimeout(2)
    try:
        c.connect(p); reached.append(p)
    except OSError:
        pass
    finally:
        c.close()
t = socket.socket(); t.settimeout(3)
try:
    t.connect(("1.1.1.1", 443)); reached.append("tcp:1.1.1.1:443")
except OSError:
    pass
print("REACHED " + " ".join(reached) if reached else "NONE")
' 2>&1)"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; rm -f "$decoy"
  case "$out" in
    NONE) echo "SANDBOX no socket or network reachable ($(grep -c . <<< "$socks") sockets tried)"; return 1 ;;
    REACHED*) echo "SANDBOX ${out}"; return 0 ;;
    *) echo "SANDBOX socket probe could not run: $out"; return 2 ;;
  esac
}
