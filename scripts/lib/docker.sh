#!/usr/bin/env bash
# docker.sh — Probe docker-daemon reachability before scripts try to drive it.
#
# Why this exists (anchored 2026-06-02): scripts/local_demo.sh and
# scripts/local-dev-up.sh used `command -v docker` as their docker
# precondition. That only checks the binary is on $PATH, NOT that the
# daemon behind the socket is reachable. The macOS colima backend
# routinely loses its SSH-tunneled docker socket forward after a Mac
# sleep/resume cycle (abiosoft/colima#460, #1170, #1033). The socket
# FILE remains at ~/.colima/default/docker.sock but nothing is listening
# on it. Result: `command -v docker` passes, then `docker compose up`
# fails deep inside the script with a confusing "Cannot connect to the
# Docker daemon" buried under cleanup output.
#
# This helper turns that into a clean fail-fast with a context-aware
# remediation hint.
#
# Probe choice: `docker version --format '{{.Server.Version}}'`. The
# `.Server.Version` template forces a real daemon round-trip; if the
# socket is reachable-but-stale the projection fails with rc != 0. We
# avoid `docker info` because it has documented false-positive output
# when the daemon is stopped (NVIDIA/NemoClaw#2348). `docker ps` works
# too and is what kubernetes-sigs/kind PR #583 settled on; we use
# `version` because the intent is clearer in shell logs.
#
# Linux future: when running on a native Linux host (no VM), the same
# helper works — the failure hint switches to `systemctl start docker`.
#
# Callers must define: log()

docker_daemon_reachable() {
    command -v docker >/dev/null 2>&1 || return 1
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

# Fail fast: print an actionable hint and exit 1. Use this from scripts
# whose work cannot proceed without docker (local-dev-up.sh, local_demo.sh,
# integration-up.sh).
require_docker_daemon() {
    if docker_daemon_reachable; then
        return 0
    fi
    _report_docker_daemon_unreachable
    exit 1
}

# Soft check: print the hint but return rc=1 instead of exiting. Use from
# cleanup scripts (local-dev-down.sh) where the rest of the cleanup
# (killing tracked PIDs) is still useful even if docker is offline.
ensure_docker_daemon_or_warn() {
    if docker_daemon_reachable; then
        return 0
    fi
    _report_docker_daemon_unreachable
    return 1
}

_report_docker_daemon_unreachable() {
    local os ctx hint
    os="$(uname -s 2>/dev/null || echo unknown)"
    # docker context show prints to stderr when no docker config exists; the
    # `|| true` ensures we still hit our case statement with an empty ctx.
    ctx="$(docker context show 2>/dev/null || true)"

    case "$os" in
        Linux)
            hint="run: sudo systemctl start docker  (or 'sudo service docker start' on non-systemd hosts)"
            ;;
        Darwin)
            case "$ctx" in
                orbstack)
                    hint="open OrbStack from the menu bar; if stuck at 'Starting', Quit and relaunch (see orbstack#2335)"
                    ;;
                colima)
                    hint="run: colima restart  (socket forward likely went stale after a sleep/resume cycle — see colima#460)"
                    ;;
                desktop-linux)
                    hint="open Docker Desktop and wait for the whale icon to settle"
                    ;;
                "")
                    hint="install Docker Desktop or Colima, then start it"
                    ;;
                *)
                    hint="start the docker backend for context '$ctx'"
                    ;;
            esac
            ;;
        *)
            hint="start the docker daemon for $os"
            ;;
    esac

    log "ERROR: docker daemon unreachable at the configured socket"
    log "  os: $os, context: ${ctx:-<none>}"
    log "  fix: $hint"
}
