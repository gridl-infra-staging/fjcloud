#!/usr/bin/env bash
# clean-orphans.sh — find and kill stale fjcloud-* dev processes left
# behind by parallel-worktree sessions that ended without teardown.
#
# What this exists to clean up (anchored 2026-06-02): on a typical week
# of parallel batman/matt dispatch, 10-15 long-running `nohup`'d dev
# binaries from past sessions (`fjcloud-api`, `fj-metering-agent`,
# `flapjack`) end up with PPID=1 and survive forever. They eat RAM and
# hold default ports (3001, 5173, 7700-7799, etc.), blocking the next
# session's `scripts/local_demo.sh`. The existing per-worktree
# `local-dev-down.sh` only cleans PIDs recorded in that worktree's
# `.local/*.pid` files — which doesn't help when:
#   - the worktree directory has since been deleted (batman cleanup)
#   - the PID file was wiped but the process kept running
#   - the kill_pid_file safety check rejected the PID (see the
#     "cargo vs fjcloud-api" comment in local-dev-down.sh)
#
# Shared-host process safety (per CLAUDE.md):
#   - This script does NOT use `killall`, `pkill -f`, or grep-derived
#     `kill` patterns. Those would match unrelated Python processes
#     (matt/batman workers, Xcode tools, Python3.framework).
#   - It enumerates by `ps -ax`, filters by exact-comm against a
#     hard-coded allowlist of dev-binary basenames, requires PPID=1
#     and minimum age, and kills one PID at a time.
#   - The allowlist is intentionally tight: extend it only after
#     auditing what other binaries with that name might exist on dev
#     hosts.
#
# Usage:
#   scripts/clean-orphans.sh                # list mode (default; safe)
#   scripts/clean-orphans.sh --kill         # SIGTERM, then SIGKILL after 5s
#   scripts/clean-orphans.sh --min-age 60   # min seconds (default 3600)
#   scripts/clean-orphans.sh --help

set -euo pipefail

# Exact `comm` (15-char short name from ps -o comm=) values we will kill.
# These are the long-running daemon binaries this repo's local stack
# produces. NOT including build artifacts like `flapjack_http-*` test
# binaries (those have hashed suffixes and are short-lived).
ORPHAN_TARGET_COMMS=(
    fjcloud-api
    fj-metering-agent
    flapjack
)

MIN_AGE_SECONDS=3600
DO_KILL=0

usage() {
    sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --kill)        DO_KILL=1; shift ;;
        --min-age)     MIN_AGE_SECONDS="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { echo "[clean-orphans] $*"; }

# Parse a BSD ps `etime` string into seconds. Format options:
#   MM:SS                  under 1 hour
#   HH:MM:SS               1-24 hours
#   DD-HH:MM:SS            over 24 hours
# We avoid `etimes=` here because macOS BSD ps doesn't support it
# (returns empty), only GNU procps does.
etime_to_seconds() {
    local etime="$1"
    local days=0 hms="$etime"
    if [[ "$etime" == *-* ]]; then
        days="${etime%%-*}"
        hms="${etime#*-}"
    fi
    local h=0 m=0 s=0
    local IFS=:
    # shellcheck disable=SC2206
    local parts=($hms)
    case "${#parts[@]}" in
        3) h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}" ;;
        2) m="${parts[0]}"; s="${parts[1]}" ;;
        1) s="${parts[0]}" ;;
        *) echo "0"; return ;;
    esac
    # Strip any leading zeros that would trigger octal interpretation
    days=$((10#${days:-0}))
    h=$((10#${h:-0}))
    m=$((10#${m:-0}))
    s=$((10#${s:-0}))
    echo $(( days * 86400 + h * 3600 + m * 60 + s ))
}

comm_is_target() {
    local base="$1"
    local target
    for target in "${ORPHAN_TARGET_COMMS[@]}"; do
        [ "$target" = "$base" ] && return 0
    done
    return 1
}

# Returns "<pid> <ppid> <etime_seconds> <comm-basename>" lines for every
# process matching any target comm exactly. Portable across BSD ps (macOS)
# and GNU procps (Linux).
#
# Avoiding `printf ... | grep -qx`: grep exits on first match, printf then
# SIGPIPEs trying to write the rest; with pipefail + set -e that aborts
# the script silently. A pure-bash array membership check (comm_is_target)
# sidesteps the whole SIGPIPE class of bug.
list_candidates() {
    # On macOS BSD ps, `comm` returns the full argv[0] path; on Linux
    # GNU ps it returns the short basename. We basename it either way.
    ps -axo pid=,ppid=,etime=,comm= 2>/dev/null \
        | while read -r pid ppid etime comm; do
            local base etimes
            base="${comm##*/}"
            [ -n "$base" ] || continue
            if comm_is_target "$base"; then
                etimes="$(etime_to_seconds "$etime")"
                printf '%s %s %s %s\n' "$pid" "$ppid" "$etimes" "$base"
            fi
        done
}

# Returns the binary path the PID is executing. Empty if lsof unavailable
# or the PID has vanished. We use this to filter further — a candidate
# only counts as an orphan if its binary lives under a target/debug or
# target/release directory (excludes any non-dev process that happens to
# share a name).
binary_path_for_pid() {
    local pid="$1"
    command -v lsof >/dev/null 2>&1 || { printf '\n'; return 0; }
    # lsof gotcha: by default `-p` and `-d` are OR'd (union of filters).
    # Without `-a`, `lsof -p 66069 -d txt` returns txt-mapped files for
    # EVERY process — which makes our awk pick the first match from any
    # process and report it as PID 66069's binary. `-a` intersects the
    # filters so we get only this PID's txt entries.
    #
    # Also wrap in `|| true` so SIGPIPE from awk's early `exit` doesn't
    # trip pipefail + set -e in the caller.
    { lsof -a -p "$pid" -d txt 2>/dev/null \
        | awk 'NR>1 && $NF ~ /target\/(debug|release)\// {print $NF; exit}'; } || true
}

# Kill one PID gracefully (SIGTERM, 5s wait, SIGKILL). Returns 0 if the
# PID is gone by the end, 1 if it survived.
kill_one() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    local elapsed=0
    while [ "$elapsed" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    return 0
}

found=0
killed=0
failed=0

if [ "$DO_KILL" -eq 1 ]; then
    log "Mode: KILL (SIGTERM, SIGKILL fallback). min-age: ${MIN_AGE_SECONDS}s"
else
    log "Mode: list only (use --kill to actually terminate). min-age: ${MIN_AGE_SECONDS}s"
fi

while read -r pid ppid etimes comm; do
    [ -z "$pid" ] && continue

    # Filter: must be orphaned (PPID=1) — guarantees no active session
    # owns it. A live `local_demo.sh` run is reaped by its launching
    # shell; orphans only happen when that shell already exited.
    [ "$ppid" = "1" ] || continue

    # Filter: must be older than the min-age threshold. Protects a stack
    # that's currently spinning up.
    [ "$etimes" -ge "$MIN_AGE_SECONDS" ] || continue

    # Filter: binary must be in a target/debug or target/release tree.
    # Excludes any unrelated process that happens to share the name.
    # Reset explicitly each iteration — main script body has no function
    # scope, so a `local` here would silently no-op and a previous
    # iteration's value could shadow an empty result.
    local_bin_path=""
    local_bin_path="$(binary_path_for_pid "$pid")"
    if [ -z "$local_bin_path" ]; then
        log "skip pid=$pid comm=$comm — could not resolve binary path (lsof unavailable or PID gone)"
        continue
    fi

    found=$((found + 1))
    age_h=$((etimes / 3600))
    age_m=$(((etimes % 3600) / 60))
    log "ORPHAN pid=$pid comm=$comm age=${age_h}h${age_m}m bin=$local_bin_path"

    if [ "$DO_KILL" -eq 1 ]; then
        if kill_one "$pid"; then
            killed=$((killed + 1))
            log "  killed"
        else
            failed=$((failed + 1))
            log "  FAILED to kill (still alive after SIGKILL)"
        fi
    fi
done < <(list_candidates)

if [ "$found" -eq 0 ]; then
    log "No orphans matched (target comms: ${ORPHAN_TARGET_COMMS[*]}, min-age ${MIN_AGE_SECONDS}s)"
    log "Summary: found=0 killed=0 failed=0"
elif [ "$DO_KILL" -eq 1 ]; then
    log "Summary: found=$found killed=$killed failed=$failed"
    [ "$failed" -eq 0 ] || exit 1
else
    log "Summary: found=$found (list-only; re-run with --kill to terminate)"
fi
