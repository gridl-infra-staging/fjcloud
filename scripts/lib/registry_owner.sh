#!/usr/bin/env bash
# Source-only owner for validating registry reasons against durable .md owners.

registry_reason_has_owner() {
    local repo_root="$1" reason="$2"
    local candidate line_number roadmap_line

    while IFS= read -r candidate; do
        case "/$candidate/" in
            *"/../"*|*"/./"*) continue ;;
        esac
        if [ "$candidate" != "ROADMAP.md" ] && [ -f "$repo_root/$candidate" ]; then
            return 0
        fi
    done < <(printf '%s\n' "$reason" | grep -Eo '([[:alnum:]_.-]+/)*[[:alnum:]_.-]+\.md' || true)

    if [[ "$reason" =~ ROADMAP\.md:([0-9]+) ]]; then
        line_number="${BASH_REMATCH[1]}"
        roadmap_line="$(sed -n "${line_number}p" "$repo_root/ROADMAP.md" 2>/dev/null || true)"
        [[ "$roadmap_line" =~ ^\|[[:space:]]*(\*\*)?P[0-9] ]]
        return $?
    fi
    return 1
}
