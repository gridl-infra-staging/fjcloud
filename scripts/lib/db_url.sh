#!/usr/bin/env bash

redact_db_url() {
    local db_url="${1:-}"
    printf '%s\n' "$db_url" | sed 's|//\([^:/@]*\):[^@]*@|//\1:***@|'
}

db_url_userinfo() {
    local db_url="${1:-}"
    db_url="${db_url#*://}"
    if [ "$db_url" = "${db_url#*@}" ]; then
        return 1
    fi
    printf '%s\n' "${db_url%%@*}"
}

db_url_user() {
    local userinfo
    userinfo="$(db_url_userinfo "$1")" || return 1
    printf '%s\n' "${userinfo%%:*}"
}

db_url_password() {
    local userinfo
    userinfo="$(db_url_userinfo "$1")" || return 1
    if [ "$userinfo" = "${userinfo#*:}" ]; then
        printf '\n'
        return 0
    fi
    printf '%s\n' "${userinfo#*:}"
}

db_url_database() {
    local db_url="${1:-}"
    db_url="${db_url#*://}"
    db_url="${db_url#*@}"
    if [ "$db_url" = "${db_url#*/}" ]; then
        return 1
    fi
    db_url="${db_url#*/}"
    printf '%s\n' "${db_url%%\?*}"
}

db_url_hostport() {
    local db_url="${1:-}"
    db_url="${db_url#*://}"
    db_url="${db_url#*@}"
    if [ "$db_url" != "${db_url#*/}" ]; then
        db_url="${db_url%%/*}"
    fi
    printf '%s\n' "$db_url"
}

db_url_host() {
    local hostport
    hostport="$(db_url_hostport "$1")"
    if [ -z "$hostport" ]; then
        return 1
    fi

    if [ "${hostport#\[}" != "$hostport" ]; then
        printf '%s]\n' "${hostport%%]*}"
        return 0
    fi

    if [ "${hostport#*:}" != "$hostport" ]; then
        printf '%s\n' "${hostport%%:*}"
        return 0
    fi

    printf '%s\n' "$hostport"
}

db_url_port_is_valid() {
    local port="${1:-}"
    case "$port" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

db_url_port() {
    local hostport remainder port
    hostport="$(db_url_hostport "$1")"
    if [ -z "$hostport" ]; then
        return 1
    fi

    if [ "${hostport#\[}" != "$hostport" ]; then
        remainder="${hostport#*]}"
        if [ -n "$remainder" ] && [ "${remainder#*:}" != "$remainder" ]; then
            port="${remainder#:}"
        else
            port="5432"
        fi
    elif [ "${hostport#*:}" != "$hostport" ]; then
        port="${hostport##*:}"
    else
        port="5432"
    fi

    db_url_port_is_valid "$port" || return 1
    printf '%s\n' "$port"
}

require_db_url_part() {
    local db_url="$1"
    local extractor="$2"
    local value

    value="$("$extractor" "$db_url")" || return 1
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}
