#!/usr/bin/env bash
# Shared health-check helpers for shell scripts.
#
# Callers must define:
#   log "<message>"

wait_for_health() {
    local url="$1" name="$2" max_wait="${3:-15}"
    local elapsed=0
    while [ $elapsed -lt "$max_wait" ]; do
        if curl -sf "$url" >/dev/null 2>&1; then
            log "$name is healthy ($url)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log "$name failed health check after ${max_wait}s ($url)"
    return 1
}

check_port_available() {
    local port="$1"
    local name="$2"

    if ! command -v lsof >/dev/null 2>&1; then
        return 0
    fi

    if ! lsof -i :"$port" -sTCP:LISTEN -P >/dev/null 2>&1; then
        return 0
    fi

    log "port $port is already in use (needed for $name)"

    # On collision, surface enough provenance for the operator (or AI agent)
    # to decide whether the holder is intentional or an orphan.
    # Anchored 2026-05-31: the previous one-line "port X unavailable"
    # message left callers with nothing to act on. A May 26 worktree's
    # orphan vite held :5173 for 5 days; only an interactive `lsof` + `ps`
    # + `lsof -d cwd` chase revealed which worktree owned the orphan.
    # Encoding that chase here means the next agent gets the answer for
    # free. Test: scripts/tests/port_collision_diagnose_test.sh.
    _report_port_holder_diagnostics "$port"

    return 1
}

# Private helper — surfaces who's holding `port`, formatted to make the
# orphan-vs-intentional-process decision easy. Best-effort: if any single
# subcommand fails we fall through quietly (the basic "port unavailable"
# log above is already on screen).
_report_port_holder_diagnostics() {
    local port="$1"

    local holder_pid
    holder_pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
    if [ -z "$holder_pid" ]; then
        return 0
    fi

    local holder_cmd holder_started holder_cwd
    # Truncate command-line to keep the log readable; the suffix is rarely
    # informative once the binary name is visible.
    holder_cmd="$(ps -o command= -p "$holder_pid" 2>/dev/null | head -c 120 | tr -d '\n' || true)"
    holder_started="$(ps -o lstart= -p "$holder_pid" 2>/dev/null | head -1 | sed 's/^ *//' || true)"
    # `lsof -p $pid -d cwd` returns a header row + one cwd row whose last
    # column is the path. NR>1 skips the header.
    holder_cwd="$(lsof -p "$holder_pid" -d cwd 2>/dev/null | awk 'NR>1 {print $NF; exit}' || true)"

    log "  holder: PID $holder_pid"
    [ -n "$holder_cmd" ]     && log "  cmd:    $holder_cmd"
    [ -n "$holder_cwd" ]     && log "  cwd:    $holder_cwd"
    [ -n "$holder_started" ] && log "  started: $holder_started"
    log "  free it:  kill $holder_pid"

    # Docker-layer probe — the host-side LISTEN we just diagnosed is often
    # only a port forwarder, not the real owner of the port. On macOS
    # Colima the host listener is `ssh: ... [mux]`; on Docker Desktop it's
    # `com.docker.backend`/vpnkit; on OrbStack it's a similar bridge. The
    # `lsof`/`ps` chain above will point at the forwarder process (whose
    # cwd is wherever the docker runtime was launched from — frequently
    # *not* the worktree the operator is in), which misleads triage into
    # thinking the conflict is host-side. The container actually
    # publishing the port lives one layer down. Asking docker directly
    # — when docker is on PATH and the daemon is reachable — surfaces the
    # real owner with a paste-able cleanup command that mirrors the
    # `kill $pid` line above.
    #
    # Anchored 2026-06-03: a stray `fj_cold_probe sleep infinity` container
    # from an ad-hoc `docker run` squatted on :7700; the original
    # diagnostic showed only the colima ssh-mux PID with a `cwd:` pointing
    # at an unrelated repo, making the failure look like a parallel
    # worktree collision when the real cause was a one-off container.
    #
    # Best-effort: if `docker` is absent (CI runners, machines without
    # docker installed) or the daemon is unreachable, the probe is a
    # silent no-op. `2>/dev/null` swallows the "Cannot connect to the
    # Docker daemon" message so a daemon-down state doesn't pollute the
    # diagnostic output.
    if command -v docker >/dev/null 2>&1; then
        local docker_holder
        docker_holder="$(docker ps --filter "publish=$port" \
            --format '{{.Names}}	{{.Image}}' 2>/dev/null | head -1 || true)"
        if [ -n "$docker_holder" ]; then
            # `cut -f` defaults to tab delimiter, matching the
            # {{.Names}}\t{{.Image}} format string above. Using cut keeps
            # this portable across bash 3.x (macOS default) where embedded
            # tab handling in ${var%%PATTERN*} is awkward.
            local container_name container_image
            container_name="$(printf '%s' "$docker_holder" | cut -f1)"
            container_image="$(printf '%s' "$docker_holder" | cut -f2)"
            log "  docker container: $container_name (image: $container_image)"
            log "  free it:  docker rm -f $container_name"
        fi
    fi
}
