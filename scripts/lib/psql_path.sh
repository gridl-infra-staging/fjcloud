#!/usr/bin/env bash
# psql_path.sh — ensure `psql` is discoverable on PATH when libpq is installed
# out-of-PATH (common with Homebrew kegs like libpq / postgresql@16 on macOS,
# and with the AL2023 postgresql16 package when it lands under /usr/pgsql-*).
#
# Idempotent: sourcing this file multiple times is safe. It does not override
# an existing PATH-resolvable `psql`; it only prepends candidate directories
# when a discoverable `psql` binary is missing.

# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
# TODO: Document ensure_psql_on_path.
ensure_psql_on_path() {
    if command -v psql >/dev/null 2>&1; then
        return 0
    fi

    local candidate
    for candidate in \
        /opt/homebrew/opt/libpq/bin \
        /opt/homebrew/opt/libpq@18/bin \
        /usr/local/opt/libpq/bin \
        /opt/homebrew/opt/postgresql@16/bin \
        /usr/local/opt/postgresql@16/bin \
        /usr/pgsql-16/bin \
        /usr/pgsql-15/bin; do
        if [ -x "$candidate/psql" ]; then
            case ":$PATH:" in
                *":$candidate:"*) ;;
                *) PATH="$candidate:$PATH" ;;
            esac
            export PATH
            return 0
        fi
    done

    return 1
}

ensure_psql_on_path || true
