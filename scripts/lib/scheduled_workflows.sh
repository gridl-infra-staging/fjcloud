#!/usr/bin/env bash
# Source-only discovery of workflows with a direct on.schedule mapping key.

scheduled_workflow_files() {
    [ "$#" -eq 1 ] || return 2
    local repo_root="$1" workflow_path
    for workflow_path in "$repo_root"/.github/workflows/*.yml "$repo_root"/.github/workflows/*.yaml; do
        [ -f "$workflow_path" ] || continue
        awk '
            function indentation(line) {
                match(line, /[^ ]/)
                return RSTART ? RSTART - 1 : length(line)
            }
            function mapping_key(line, key) {
                key = line
                sub(/^[[:space:]]*/, "", key)
                if (key !~ /^["'"'"']?[[:alnum:]_-]+["'"'"']?[[:space:]]*:/) {
                    return ""
                }
                sub(/[[:space:]]*:.*/, "", key)
                gsub(/^["'"'"']|["'"'"']$/, "", key)
                return key
            }
            {
                line = $0
                sub(/[[:space:]]+#.*/, "", line)
                key = mapping_key(line)
                if (key == "") {
                    next
                }
                indent = indentation(line)
                if (indent == 0) {
                    in_on = (key == "on")
                    direct_child_indent = -1
                    next
                }
                if (!in_on) {
                    next
                }
                if (direct_child_indent < 0) {
                    direct_child_indent = indent
                }
                if (indent == direct_child_indent && key == "schedule") {
                    found = 1
                }
            }
            END { exit !found }
        ' "$workflow_path" && basename "$workflow_path"
    done | LC_ALL=C sort
}
