#!/usr/bin/env bash
# sandbox.sh - source me. Runs code under test (build scripts, proc macros, tests, Lean elaboration)
# so that it cannot rewrite the evidence that judges it (threat CI-9 / ROADMAP O1).
#
#   sandbox <cmd...>   run <cmd> in a bubblewrap jail:
#       read-only : the whole filesystem (repo, evidence, scripts, .git, toolchains, the dependency cache
#                   ~/.cargo/registry + git, $RUNNER_TEMP with GITHUB_ENV/GITHUB_OUTPUT files)
#       hidden    : $HOME (an empty tmpfs; only ~/.cargo ~/.rustup ~/.elan ~/.kani come back, read-only) -
#                   no ~/.ssh, ~/.config/gh, ... for the code under test to read and print into the logs
#       writable  : a fresh private TMPDIR (removed afterwards), $CARGO_TARGET_DIR, the current directory when it is under
#                   the run's work dir ($SANDBOX_WORK), every path in $SANDBOX_RW (":"-separated, no symlinks)
#       environment: cleared; only toolchain variables (PATH, CARGO_*, RUSTUP_*, RUST*, LEAN/ELAN/LAKE*, KANI*,
#                   NEXTEST_*, LLVM_*, locale) and the names in $SANDBOX_ENV_KEEP pass in
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
  # SANDBOX_NOPROC=1: no procfs at all - /proc/self/mem would let safe code rewrite its own memory (coverage
  # counters, #45 item 7); used for running test binaries, not for cargo/rustc (rustup needs /proc)
  local procfs=(--proc /proc); [ "${SANDBOX_NOPROC:-0}" = 1 ] && procfs=(--tmpfs /proc)
  local args=(--ro-bind / / --dev /dev "${procfs[@]}"
              --unshare-pid --unshare-net --unshare-ipc --die-with-parent --new-session
              --setenv CARGO_NET_OFFLINE true)
  # unix sockets: an empty /run and /tmp hide docker.sock, dbus, systemd and stray /tmp sockets; any other socket
  # found by sandbox_enable is masked with /dev/null. The run's own WORK stays visible (read-only).
  # environment: start empty, pass toolchain variables only (secrets in the caller's env stay outside)
  args+=(--clearenv)
  local v
  while IFS='=' read -r v _; do
    case "$v" in
      PATH|HOME|USER|LOGNAME|SHELL|TERM|TZ|LANG|LC_*|CARGO_*|RUSTUP_*|RUSTC*|RUSTDOC*|RUSTFLAGS|RUST_*|ELAN_*|LEAN_*|LAKE_*|KANI_*|NEXTEST_*|LLVM_*|CC|CXX|AR) ;;
      *) [[ " ${SANDBOX_ENV_KEEP:-} " == *" $v "* ]] || continue ;;
    esac
    case "$v" in GITHUB_*|ACTIONS_*|*TOKEN*|*SECRET*|*PASSWORD*|*_KEY) continue ;; esac
    args+=(--setenv "$v" "${!v}")
  done < <(compgen -e | sed 's/$/=/')
  # $HOME: empty, then the toolchain directories read-only (credentials, ssh keys, gh config stay hidden)
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ] && [ "$HOME" != / ]; then
    args+=(--tmpfs "$HOME")
    for p in .cargo .rustup .elan .kani; do [ -e "$HOME/$p" ] && args+=(--ro-bind "$HOME/$p" "$HOME/$p"); done
    # what the command needs to read comes back read-only: the project it runs in (git top level of the cwd),
    # the Actions work dir (checkout + RUNNER_TEMP toolchains), the run's WORK and any $SANDBOX_RO path
    local top; top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
    for p in "$top" "$cwd" ${GITHUB_WORKSPACE:+"$(dirname "$GITHUB_WORKSPACE")"}; do
      [[ "$p/" == "$HOME/"* && -e "$p" ]] && args+=(--ro-bind "$p" "$p")
    done
  fi
  [ -d /run ] && args+=(--tmpfs /run)
  args+=(--tmpfs /tmp)
  # linked toolchains (elan/rustup `toolchain link` to e.g. $RUNNER_TEMP/lean-tc) point outside the hidden $HOME
  for p in "${HOME:-/nonexistent}"/.elan/toolchains/* "${HOME:-/nonexistent}"/.rustup/toolchains/*; do
    [ -L "$p" ] && [ -e "$p" ] && args+=(--ro-bind "$(realpath -- "$p")" "$(realpath -- "$p")")
  done
  if [ -n "${SANDBOX_WORK:-}" ]; then args+=(--ro-bind "$SANDBOX_WORK" "$SANDBOX_WORK"); fi
  [ -n "${CARGO_TARGET_DIR:-}" ] && [ -e "$CARGO_TARGET_DIR" ] && args+=(--ro-bind "$CARGO_TARGET_DIR" "$CARGO_TARGET_DIR")
  # the directory the command runs in must stay visible (read-only unless granted below), also under /tmp
  case "$cwd" in /tmp|/tmp/*) args+=(--ro-bind "$cwd" "$cwd") ;; esac
  if [ -n "${SANDBOX_RO:-}" ]; then IFS=: read -ra p <<< "$SANDBOX_RO"; for a in "${p[@]}"; do [ -e "$a" ] && args+=(--ro-bind "$a" "$a"); done; fi
  while IFS= read -r s; do [ -n "$s" ] && [ -S "$s" ] && args+=(--ro-bind /dev/null "$s"); done <<< "${SANDBOX_SOCKS:-}"
  tmp="$(mktemp -d "${SANDBOX_WORK:-${TMPDIR:-/tmp}}/sbx-tmp.XXXXXX")" || { echo "SANDBOX no temp dir"; return 125; }
  local rw=("$tmp")
  [ -n "${CARGO_TARGET_DIR:-}" ] && { mkdir -p "$CARGO_TARGET_DIR"; rw+=("$CARGO_TARGET_DIR"); }
  if [ -n "${SANDBOX_WORK:-}" ] && [[ "$cwd/" == "$SANDBOX_WORK/"* ]]; then rw+=("$cwd"); fi
  if [ -n "${SANDBOX_RW:-}" ]; then
    IFS=: read -ra p <<< "$SANDBOX_RW"
    # an explicit writable path that does not exist is a caller bug: fail loudly instead of a silent read-only run
    for a in "${p[@]}"; do
      [ -e "$a" ] || { echo "SANDBOX writable path missing: $a (cwd $cwd)" >&2; return 125; }
      # a symlink anywhere in the path would re-mount its TARGET writable (e.g. a committed link to $RUNNER_TEMP)
      [ "$(realpath -s -- "$a")" = "$(realpath -- "$a")" ] || { echo "SANDBOX writable path is or passes through a symlink: $a -> $(realpath -- "$a")" >&2; return 125; }
    done
    rw+=("${p[@]}")
  fi
  # the dependency cache stays read-only: dependencies are fetched before any jailed step (S0f), and a writable
  # cache let a test rewrite a dependency's sources for every later gate (and later builds on the host)
  for p in "${rw[@]}"; do [ -n "$p" ] && [ -e "$p" ] && { p="$(realpath -- "$p")"; args+=(--bind "$p" "$p"); }; done
  # Docker Desktop publishes host-service sockets under this WSL mount. Hide the
  # shared mount after all host binds, including sockets created after discovery.
  if [ -d /mnt/wsl ]; then args+=(--tmpfs /mnt/wsl); fi
  args+=(--setenv TMPDIR "$tmp" --chdir "$cwd")
  "$SANDBOX_BWRAP" "${args[@]}" -- "$@"; rc=$?
  rm -rf "$tmp"; return "$rc"
}

sandbox_cargo() {
  local sub="" a i=0 n=$#
  local -a argv=("$@") pre=() post=()
  # first non-option argument is the subcommand (cargo +toolchain / -q forms)
  for a in "$@"; do i=$((i + 1)); case "$a" in +*|-*) pre+=("$a") ;; *) sub="$a"; post=("${argv[@]:i}"); break ;; esac; done
  case "$sub" in
    # Network steps (download only) run OUTSIDE the jail but from an empty directory with explicit paths:
    # cargo reads .cargo/config.toml from the cwd, and a checkout-controlled build.rustc-wrapper runs even
    # during `cargo fetch` / `cargo metadata` (rustc -vV). From $SANDBOX_NEUTRAL no project config is read.
    fetch|metadata|deny|audit) sandbox_cargo_neutral "$sub" "$(pwd -P)" "${pre[@]}" -- "${post[@]}" ;;
    --version|-V|version|"") ( cd "$SANDBOX_NEUTRAL" && command cargo "$@" ) ;;
    *) sandbox cargo "$@" ;;   # build, test, clippy, fmt, nextest, llvm-cov, mutants, kani, fuzz, run, ...
  esac
}

sandbox_cargo_neutral() { # <sub> <project dir> <pre-args...> -- <post-args...>
  local sub="$1" proj="$2" a; shift 2
  local -a pre=() post=() extra=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do pre+=("$1"); shift; done; shift
  post=("$@")
  has() { local x; for x in "${post[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
  case "$sub" in
    fetch|metadata) has --manifest-path || extra=(--manifest-path "$proj/Cargo.toml") ;;
    deny) has --manifest-path || extra=(--manifest-path "$proj/Cargo.toml")
          # deny reads <cwd>/deny.toml by default: name the project's file (global option)
          if [ -f "$proj/deny.toml" ] && ! has --config; then extra+=(--config "$proj/deny.toml"); fi
          # cargo-deny runs `cargo metadata` with the manifest dir as cwd (project config -> wrapper runs):
          # hand it metadata computed here, from the neutral dir, instead
          if ! has --metadata-path; then
            local meta; meta="$(mktemp "$SANDBOX_NEUTRAL/meta.XXXXXX")" || return 2
            ( cd "$SANDBOX_NEUTRAL" && command cargo metadata --format-version 1 --manifest-path "$proj/Cargo.toml" ) > "$meta" \
              || { echo "SANDBOX cargo metadata failed for $proj" >&2; return 2; }
            extra+=(--metadata-path "$meta")
          fi ;;
    audit) has -f || has --file || extra=(-f "$proj/Cargo.lock") ;;
  esac
  ( cd "$SANDBOX_NEUTRAL" && command cargo "${pre[@]}" "$sub" "${extra[@]}" "${post[@]}" )
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
  [ -n "${SANDBOX_NEUTRAL:-}" ] && [ -d "$SANDBOX_NEUTRAL" ] || SANDBOX_NEUTRAL="$(mktemp -d "${TMPDIR:-/tmp}/sbx-neutral.XXXXXX")"
  export SANDBOX_SOCKS SANDBOX_NEUTRAL
  cargo() { sandbox_cargo "$@"; }
  elan() { sandbox_elan "$@"; }
  export -f sandbox sandbox_cargo sandbox_cargo_neutral sandbox_elan cargo elan jail_armed
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
