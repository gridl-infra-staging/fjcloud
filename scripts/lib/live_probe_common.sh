#!/usr/bin/env bash

live_probe_is_absolute_executable() {
    local path="$1"

    case "$path" in
        /*) ;;
        *) return 1 ;;
    esac
    [ -x "$path" ]
}

live_probe_file_exists() {
    local path="$1"

    [ -f "$path" ]
}

