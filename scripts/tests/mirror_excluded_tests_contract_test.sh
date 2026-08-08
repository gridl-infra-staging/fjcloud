#!/usr/bin/env bash
# Contract test for the staging-mirror exclusion registry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_SCRIPT="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="${FJCLOUD_MIRROR_CONTRACT_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
REGISTRY_PATH="$REPO_ROOT/scripts/tests/mirror_excluded_tests.txt"
DEBBIE_TOML="$REPO_ROOT/.debbie.toml"
MANIFEST_PATH="$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"
EXPECTED_MIRROR_EXCLUDED_TEST_COUNT="${FJCLOUD_MIRROR_CONTRACT_EXPECTED_COUNT:-29}"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"

MANIFEST_TESTS=()
REGISTRY_SUITES=()
REGISTRY_DECLARED_PATHS=()
REGISTRY_ROWS=()
SYNC_FILES=()
SYNC_DIRS=()
SYNC_EXCLUDE_DIRS=()
SYNC_EXCLUDE_PATTERNS=()
MIRROR_ABSENT_PATHS_FILE=""
MIRROR_ABSENT_REFERENCES_FILE=""

trim_space() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

append_non_comment_content() {
    local path="$1"
    # The repository's executable roots use shell/Python '#' comments and
    # JavaScript '//' comments. Comment-only mentions are documentation, not
    # execution edges, so neither form is allowed to manufacture reachability.
    awk '
        {
            text = $0
            sub(/^[[:space:]]*/, "", text)
            if (text ~ /^#/ || text ~ /^\/\//) {
                next
            }
            print $0
        }
    ' "$path" >> "$CONTENT_FILE"
}

report_assertion() {
    local label="$1" denominator="$2" failures="$3" message="$4"
    if [ "$denominator" -eq 0 ]; then
        echo "VACUOUS: $label n=0 $message" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi
    if [ "$failures" -eq 0 ]; then
        pass "$label n=$denominator $message"
    else
        fail "$label n=$denominator $message failures=$failures"
    fi
}

load_manifest() {
    local line
    while IFS= read -r line; do
        line="$(trim_space "$line")"
        if [[ "$line" =~ ^\"(scripts/tests/[^[:space:]\"]+\.sh)\"$ ]]; then
            MANIFEST_TESTS+=("${BASH_REMATCH[1]}")
        fi
    done < "$MANIFEST_PATH"
}

load_registry() {
    local line trimmed line_number suite rest path_list reason path
    local row_count=0
    line_number=0

    if [ ! -f "$REGISTRY_PATH" ]; then
        fail "registry file exists at scripts/tests/mirror_excluded_tests.txt"
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        trimmed="$(trim_space "$line")"
        if [ -z "$trimmed" ] || [[ "$trimmed" = \#* ]]; then
            continue
        fi
        row_count=$((row_count + 1))

        if [[ "$trimmed" != scripts/tests/*" # "* || "$trimmed" != *" — "* ]]; then
            fail "registry row $line_number has format scripts/tests/<name>.sh # <path>[,<path>...] — <reason>"
            continue
        fi

        suite="${trimmed%% # *}"
        rest="${trimmed#* # }"
        path_list="${rest%% — *}"
        reason="${rest#* — }"
        if [ -z "$suite" ] || [ -z "$path_list" ] || [ -z "$reason" ] || [ "$reason" = "$rest" ]; then
            fail "registry row $line_number has non-empty suite, path list, and reason"
            continue
        fi

        REGISTRY_SUITES+=("$suite")
        REGISTRY_ROWS+=("$trimmed")
        IFS=',' read -r -a row_paths <<< "$path_list"
        for path in "${row_paths[@]}"; do
            path="$(trim_space "$path")"
            if [ -z "$path" ]; then
                fail "registry row $line_number has an empty declared path"
            else
                REGISTRY_DECLARED_PATHS+=("$suite|$path")
            fi
        done
    done < "$REGISTRY_PATH"

    ENTRY_COUNT="$row_count"
}

load_debbie_sync_scope() {
    local line trimmed current_dir_index=-1 in_files=false in_exclude=false
    local in_sync_section=false in_sync_dir_block=false

    if [ ! -f "$DEBBIE_TOML" ]; then
        fail "required .debbie.toml exists"
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="$(trim_space "${line%%#*}")"
        if [ -z "$trimmed" ]; then
            continue
        fi

        if [ "$trimmed" = "[sync]" ]; then
            in_sync_section=true
            in_sync_dir_block=false
            current_dir_index=-1
            in_files=false
            in_exclude=false
            continue
        fi
        if [ "$trimmed" = "[[sync.dirs]]" ]; then
            in_sync_section=false
            in_sync_dir_block=true
            current_dir_index=-1
            in_files=false
            in_exclude=false
            continue
        fi
        if [[ "$trimmed" =~ ^\[.*\] ]]; then
            in_sync_section=false
            in_sync_dir_block=false
            current_dir_index=-1
            in_files=false
            in_exclude=false
            continue
        fi
        if [ "$in_sync_section" = true ] && [[ "$trimmed" =~ ^files[[:space:]]*=[[:space:]]*\[ ]]; then
            in_files=true
            in_exclude=false
            continue
        fi
        if [ "$in_sync_dir_block" = true ] && [[ "$trimmed" =~ ^exclude[[:space:]]*=[[:space:]]*\[ ]]; then
            in_files=false
            in_exclude=true
            continue
        fi
        if [ "$trimmed" = "]" ]; then
            in_files=false
            in_exclude=false
            continue
        fi
        if [ "$in_sync_dir_block" = true ] && [[ "$trimmed" =~ ^path[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
            SYNC_DIRS+=("${BASH_REMATCH[1]}")
            current_dir_index=$((${#SYNC_DIRS[@]} - 1))
            continue
        fi
        if [[ "$trimmed" =~ \"([^\"]+)\" ]]; then
            if [ "$in_files" = true ]; then
                SYNC_FILES+=("${BASH_REMATCH[1]}")
            elif [ "$in_exclude" = true ] && [ "$current_dir_index" -ge 0 ]; then
                SYNC_EXCLUDE_DIRS+=("${SYNC_DIRS[$current_dir_index]}")
                SYNC_EXCLUDE_PATTERNS+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$DEBBIE_TOML"
}

exclude_pattern_matches() {
    local relative_path="$1" pattern="$2"
    local prefix="${pattern%/}"
    if [[ "$relative_path" == "$prefix" || "$relative_path" == "$prefix/"* ]]; then
        return 0
    fi
    if [[ "$relative_path" == $pattern ]]; then
        return 0
    fi
    return 1
}

is_excluded_under_sync_dir() {
    local dir="$1" relative_path="$2"
    local i
    for ((i = 0; i < ${#SYNC_EXCLUDE_PATTERNS[@]}; i++)); do
        if [ "${SYNC_EXCLUDE_DIRS[$i]}" = "$dir" ] &&
            exclude_pattern_matches "$relative_path" "${SYNC_EXCLUDE_PATTERNS[$i]}"; then
            return 0
        fi
    done
    return 1
}

is_synced_path() {
    local path="$1" i dir relative_path
    for ((i = 0; i < ${#SYNC_FILES[@]}; i++)); do
        if [ "$path" = "${SYNC_FILES[$i]}" ]; then
            return 0
        fi
    done
    for ((i = 0; i < ${#SYNC_DIRS[@]}; i++)); do
        dir="${SYNC_DIRS[$i]}"
        if [[ "$path" == "$dir"* ]]; then
            relative_path="${path#"$dir"}"
            if [ -n "$relative_path" ] && ! is_excluded_under_sync_dir "$dir" "$relative_path"; then
                return 0
            fi
        fi
    done
    return 1
}

write_mirror_absent_paths() {
    local i synced_paths_file sync_files_spec sync_dirs_spec sync_excludes_spec tracked_paths_file
    MIRROR_ABSENT_PATHS_FILE="$WORK_DIR/mirror_absent_paths.txt"
    MIRROR_ABSENT_REFERENCES_FILE="$WORK_DIR/mirror_absent_references.txt"
    synced_paths_file="$WORK_DIR/mirror_synced_paths.txt"
    sync_files_spec="$WORK_DIR/sync_files.txt"
    sync_dirs_spec="$WORK_DIR/sync_dirs.txt"
    sync_excludes_spec="$WORK_DIR/sync_excludes.tsv"
    tracked_paths_file="$WORK_DIR/tracked_paths.txt"
    : > "$MIRROR_ABSENT_PATHS_FILE"
    : > "$synced_paths_file"
    : > "$sync_files_spec"
    : > "$sync_dirs_spec"
    : > "$sync_excludes_spec"

    for ((i = 0; i < ${#SYNC_FILES[@]}; i++)); do
        printf '%s\n' "${SYNC_FILES[$i]}" >> "$sync_files_spec"
    done
    for ((i = 0; i < ${#SYNC_DIRS[@]}; i++)); do
        printf '%s\n' "${SYNC_DIRS[$i]}" >> "$sync_dirs_spec"
    done
    for ((i = 0; i < ${#SYNC_EXCLUDE_PATTERNS[@]}; i++)); do
        printf '%s\t%s\n' "${SYNC_EXCLUDE_DIRS[$i]}" "${SYNC_EXCLUDE_PATTERNS[$i]}" >> "$sync_excludes_spec"
    done

    git -C "$REPO_ROOT" ls-files | LC_ALL=C sort > "$tracked_paths_file"
    python3 - "$sync_files_spec" "$sync_dirs_spec" "$sync_excludes_spec" \
        "$tracked_paths_file" "$MIRROR_ABSENT_PATHS_FILE" "$synced_paths_file" <<'PY'
import fnmatch
import pathlib
import sys

sync_files = {
    line.strip()
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
}
sync_dirs = [
    line.strip()
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
exclude_by_dir = {}
for line in pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    sync_dir, pattern = line.split("\t", 1)
    exclude_by_dir.setdefault(sync_dir, []).append(pattern)

def exclude_pattern_matches(relative_path, pattern):
    prefix = pattern.rstrip("/")
    if relative_path == prefix or relative_path.startswith(prefix + "/"):
        return True
    return fnmatch.fnmatchcase(relative_path, pattern)

def is_synced_path(path):
    if path in sync_files:
        return True
    for sync_dir in sync_dirs:
        if not path.startswith(sync_dir):
            continue
        relative_path = path[len(sync_dir):]
        if relative_path and not any(
            exclude_pattern_matches(relative_path, pattern)
            for pattern in exclude_by_dir.get(sync_dir, [])
        ):
            return True
    return False

tracked = pathlib.Path(sys.argv[4])
absent = pathlib.Path(sys.argv[5])
synced = pathlib.Path(sys.argv[6])
with absent.open("w", encoding="utf-8") as absent_file, synced.open("w", encoding="utf-8") as synced_file:
    for raw_path in tracked.read_text(encoding="utf-8").splitlines():
        path = raw_path.strip()
        if not path:
            continue
        if is_synced_path(path):
            synced_file.write(path + "\n")
        else:
            absent_file.write(path + "\n")
PY

    python3 - "$MIRROR_ABSENT_PATHS_FILE" "$synced_paths_file" > "$MIRROR_ABSENT_REFERENCES_FILE" <<'PY'
import pathlib
import sys

def load_paths(path):
    return {
        line.strip()
        for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines()
        if line.strip()
    }

absent_paths = load_paths(sys.argv[1])
synced_paths = load_paths(sys.argv[2])
synced_directories = {
    str(parent)
    for path in synced_paths
    for parent in pathlib.PurePosixPath(path).parents
    if str(parent) != "."
}
absent_references = set(absent_paths)
for path in absent_paths:
    absent_references.update(
        str(parent)
        for parent in pathlib.PurePosixPath(path).parents
        if str(parent) != "."
        and str(parent) not in synced_directories
        and ("/" in str(parent) or not str(parent).startswith("."))
    )

print("\n".join(sorted(absent_references)))
PY
}

check_entries_are_manifest_tests() {
    local suite failures=0 i
    # Bash 3.2 aborts on "${arr[@]}" when the array is empty under `set -u`
    # (a comment-only registry leaves REGISTRY_SUITES empty). Index loops and
    # the ${arr[@]+…} guard keep every assertion 3.2-safe so child fixtures
    # run to their summary instead of masking-aborting mid-scan.
    for ((i = 0; i < ${#REGISTRY_SUITES[@]}; i++)); do
        suite="${REGISTRY_SUITES[$i]}"
        if ! array_contains "$suite" ${MANIFEST_TESTS[@]+"${MANIFEST_TESTS[@]}"}; then
            echo "A: registry suite is not in TEST_REACHABILITY_HERMETIC_TESTS: $suite" >&2
            failures=$((failures + 1))
        fi
    done
    report_assertion "A" "$ENTRY_COUNT" "$failures" "registry entries name manifest suites"
}

check_declared_paths_are_referenced() {
    local pair suite declared_path content_file failures=0 i
    for ((i = 0; i < ${#REGISTRY_DECLARED_PATHS[@]}; i++)); do
        pair="${REGISTRY_DECLARED_PATHS[$i]}"
        suite="${pair%%|*}"
        declared_path="${pair#*|}"
        content_file="$WORK_DIR/body_${suite//\//_}"
        CONTENT_FILE="$content_file"
        : > "$CONTENT_FILE"
        if [ ! -f "$REPO_ROOT/$suite" ]; then
            echo "B: registry suite body is missing: $suite" >&2
            failures=$((failures + 1))
            continue
        fi
        append_non_comment_content "$REPO_ROOT/$suite"
        if ! grep -Fq -- "$declared_path" "$CONTENT_FILE"; then
            echo "B: registry path is not referenced by suite body: $suite # $declared_path" >&2
            failures=$((failures + 1))
        fi
    done
    report_assertion "B" "${#REGISTRY_DECLARED_PATHS[@]}" "$failures" "declared mirror-absent paths are referenced"
}

check_declared_paths_are_mirror_absent() {
    local pair declared_path failures=0 i
    for ((i = 0; i < ${#REGISTRY_DECLARED_PATHS[@]}; i++)); do
        pair="${REGISTRY_DECLARED_PATHS[$i]}"
        declared_path="${pair#*|}"
        if is_synced_path "$declared_path"; then
            echo "C: registry path is inside .debbie sync whitelist: $declared_path" >&2
            failures=$((failures + 1))
        fi
    done
    report_assertion "C" "${#REGISTRY_DECLARED_PATHS[@]}" "$failures" "declared paths are outside .debbie sync whitelist"
}

check_non_excluded_suites_are_clean() {
    local suite content_file matches_file target_file failures=0 denominator=0
    local i
    target_file="$WORK_DIR/d_scan_targets.txt"
    matches_file="$WORK_DIR/d_matches.txt"
    : > "$target_file"
    for ((i = 0; i < ${#MANIFEST_TESTS[@]}; i++)); do
        suite="${MANIFEST_TESTS[$i]}"
        if array_contains "$suite" ${REGISTRY_SUITES[@]+"${REGISTRY_SUITES[@]}"}; then
            continue
        fi
        denominator=$((denominator + 1))
        content_file="$WORK_DIR/body_${suite//\//_}"
        CONTENT_FILE="$content_file"
        : > "$CONTENT_FILE"
        append_non_comment_content "$REPO_ROOT/$suite"
        printf '%s\t%s\n' "$suite" "$CONTENT_FILE" >> "$target_file"
    done

    python3 - "$MIRROR_ABSENT_REFERENCES_FILE" "$target_file" > "$matches_file" <<'PY'
import pathlib
import re
import shlex
import sys

absent_paths = [
    line.strip()
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
absent_path_set = set(absent_paths)
targets = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()

NON_OPERAND_LEADERS = {
    "case",
    "class",
    "def",
    "elif",
    "else",
    "export",
    "fi",
    "for",
    "function",
    "if",
    "in",
    "local",
    "readonly",
    "return",
    "then",
    "while",
}

HEREDOC_REDIRECT_PATTERN = re.compile(
    r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))"
)

def heredoc_redirects(line, quote, arithmetic_depth):
    """Collect real heredoc redirects and carry shell parser state forward.

    `<<EOF` is only a redirect where the shell reads it as syntax. Inside a
    quoted string or a trailing comment it is ordinary text, and treating it as
    a redirect would swallow every following line up to a delimiter that never
    arrives — silently discarding the executable dependencies assertion D
    exists to find. Arithmetic left shifts are also spelled `<<`, so track
    `$(( ... ))` and `(( ... ))` regions and only match redirects in ordinary,
    unquoted, uncommented shell syntax.
    """
    redirects = []
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and quote != "'":
            # Outside single quotes a backslash escapes the next character,
            # so neither it nor the escaped character can change quote state.
            index += 2
            continue
        if quote is None:
            if char in "'\"":
                quote = char
                index += 1
                continue
            if char == "#" and (index == 0 or line[index - 1] in " \t;&|("):
                break
            if arithmetic_depth:
                if line.startswith("))", index):
                    arithmetic_depth -= 1
                    index += 2
                else:
                    index += 1
                continue
            if line.startswith("$((", index):
                arithmetic_depth += 1
                index += 3
                continue
            if line.startswith("((", index):
                arithmetic_depth += 1
                index += 2
                continue
            if line.startswith("<<", index):
                match = HEREDOC_REDIRECT_PATTERN.match(line, index)
                if match:
                    delimiter = next(
                        group for group in match.groups() if group is not None
                    )
                    redirects.append((delimiter, match.group(0).startswith("<<-")))
                    # Skip past the delimiter so its own quotes (`<<'EOF'`) are
                    # not mistaken for the start of a quoted string.
                    index = match.end()
                    continue
                # `<<<` here-strings and `<<` with no delimiter open nothing.
                index += 2
                continue
        elif char == quote:
            quote = None
            index += 1
            continue
        index += 1
    return redirects, quote, arithmetic_depth

def odd_trailing_backslash(line):
    return (len(line) - len(line.rstrip("\\"))) % 2 == 1

def executable_shell_body(body):
    executable_lines = []
    pending_heredocs = []
    command_heredocs = []
    quote = None
    arithmetic_depth = 0
    for physical in body.splitlines():
        if pending_heredocs:
            delimiter, strip_tabs = pending_heredocs[0]
            candidate = physical.lstrip("\t") if strip_tabs else physical
            if candidate == delimiter:
                pending_heredocs.pop(0)
            continue

        executable_lines.append(physical)
        line_redirects, quote, arithmetic_depth = heredoc_redirects(
            physical, quote, arithmetic_depth
        )
        command_heredocs.extend(line_redirects)
        if odd_trailing_backslash(physical):
            continue
        if command_heredocs:
            pending_heredocs.extend(command_heredocs)
            command_heredocs = []
    return "\n".join(executable_lines)

def logical_shell_lines(body):
    # Join `\`-continued physical lines into the single logical command the
    # shell executes, so an operand on a continuation line (`rg needle \` +
    # newline + `deliverables`) is tokenized as part of `rg needle deliverables`
    # instead of being split off and dropped by the arity guard below.
    buffer = ""
    for physical in body.splitlines():
        if odd_trailing_backslash(physical):
            buffer += physical[:-1]
            continue
        yield buffer + physical
        buffer = ""
    if buffer:
        yield buffer

def shell_operand_tokens(body):
    tokens = set()
    for line in logical_shell_lines(body):
        try:
            words = shlex.split(line, comments=False, posix=True)
        except ValueError:
            continue
        if len(words) < 2 or words[0] in NON_OPERAND_LEADERS:
            continue
        tokens.update(
            word
            for word in words[1:]
            if "=" not in word and word not in NON_OPERAND_LEADERS
        )
    return tokens

for target in targets:
    suite, content_path = target.split("\t", 1)
    body = pathlib.Path(content_path).read_text(encoding="utf-8", errors="replace")
    executable_body = executable_shell_body(body)
    # Full paths are sufficiently specific to scan throughout executable
    # language payloads (Python, awk, SQL, and similar heredocs). Bare
    # top-level names need shell-operand context, so only that channel strips
    # heredoc payloads and joins logical shell commands.
    path_tokens = set(re.findall(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", body))
    shell_tokens = shell_operand_tokens(executable_body)
    matches = sorted(
        path
        for path in absent_path_set
        if ("/" in path or path.startswith(".")) and path in path_tokens
        or ("/" not in path and not path.startswith(".") and path in shell_tokens)
    )
    for match in matches:
        print(f"{suite}\t{match}")
PY

    if [ -s "$matches_file" ]; then
        failures="$(cut -f1 "$matches_file" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
        while IFS= read -r suite; do
            echo "D: non-excluded suite references mirror-absent paths: $suite" >&2
            awk -F '\t' -v suite="$suite" '$1 == suite { print "D:   " $2 }' "$matches_file" >&2
        done < <(cut -f1 "$matches_file" | LC_ALL=C sort -u)
    fi
    report_assertion "D" "$denominator" "$failures" "non-excluded manifest suites have no mirror-absent references"
}

script_body() {
    printf '%s\n' "$@"
}

write_child_contract_fixture() {
    local fixture_root="$1" reader_suite="$2" reader_body="$3" include_reader="$4"
    mkdir -p "$fixture_root/deliverables" "$fixture_root/docs/private" \
        "$fixture_root/scripts/lib" "$fixture_root/scripts/tests"
    {
        printf '%s\n' \
            '[sync]' \
            'files = [' \
            '    ".debbie.toml",' \
            '    "scripts/lib/test_reachability_manifest.sh",' \
            '    "scripts/tests/excluded_reader_test.sh",'
        if [ "$include_reader" = true ]; then
            printf '    "%s",\n' "$reader_suite"
        fi
        printf '%s\n' '    "scripts/tests/mirror_excluded_tests.txt",' ']'
    } > "$fixture_root/.debbie.toml"
    printf '%s\n' 'private fixture' > "$fixture_root/deliverables/specimen.txt"
    printf '%s\n' 'private fixture' > "$fixture_root/docs/private/specimen.txt"
    {
        printf '%s\n' \
            'TEST_REACHABILITY_HERMETIC_TESTS=(' \
            '    "scripts/tests/excluded_reader_test.sh"'
        if [ "$include_reader" = true ]; then
            printf '    "%s"\n' "$reader_suite"
        fi
        printf '%s\n' ')'
    } > "$fixture_root/scripts/lib/test_reachability_manifest.sh"
    printf '%s\n' \
        'scripts/tests/excluded_reader_test.sh # docs/private/specimen.txt — fixture exclusion keeps A/B/C non-vacuous.' \
        > "$fixture_root/scripts/tests/mirror_excluded_tests.txt"
    printf '%s\n' '#!/usr/bin/env bash' 'test -f docs/private/specimen.txt' \
        > "$fixture_root/scripts/tests/excluded_reader_test.sh"
    if [ "$include_reader" = true ]; then
        printf '%s' "$reader_body" > "$fixture_root/$reader_suite"
    fi
    git -C "$fixture_root" init -q
    git -C "$fixture_root" add -- .
}

run_child_contract_fixture() {
    local fixture_name="$1" reader_body="$2" expectation="$3"
    local fixture_root="$WORK_DIR/$fixture_name" reader_suite output status
    local include_reader=true
    reader_suite="scripts/tests/$fixture_name"_test.sh
    if [ "$expectation" = vacuous ]; then
        include_reader=false
    fi
    write_child_contract_fixture \
        "$fixture_root" "$reader_suite" "$reader_body" "$include_reader"

    if output="$(
        FJCLOUD_MIRROR_CONTRACT_REPO_ROOT="$fixture_root" \
        FJCLOUD_MIRROR_CONTRACT_EXPECTED_COUNT=1 \
        FJCLOUD_MIRROR_CONTRACT_SKIP_REGRESSION=1 \
        bash "$CONTRACT_SCRIPT" 2>&1
    )"; then
        status=0
    else
        status=$?
    fi

    case "$expectation" in
        accept)
            if [ "$status" -eq 0 ]; then
                pass "D regression: $fixture_name fixture remains mirror-safe"
            else
                fail "D regression: $fixture_name fixture created a false dependency"
                printf '%s\n' "$output" >&2
            fi
            ;;
        vacuous)
            if [ "$status" -ne 0 ] && grep -Fq 'VACUOUS: D n=0' <<< "$output"; then
                pass "vacuous regression: zero-denominator assertion reports VACUOUS and exits red"
            else
                fail "vacuous regression: zero-denominator assertion must report VACUOUS and exit red"
                printf '%s\n' "$output" >&2
            fi
            ;;
        *)
            if [ "$status" -ne 0 ] && grep -Fq \
                "D: non-excluded suite references mirror-absent paths: $reader_suite" \
                <<< "$output" && grep -Fq "D:   $expectation" <<< "$output"; then
                pass "D regression: $fixture_name fixture reports $expectation"
            else
                fail "D regression: $fixture_name fixture must report $expectation and exit red"
                printf '%s\n' "$output" >&2
            fi
            ;;
    esac
}

check_entry_count_matches_pin() {
    if [ "$ENTRY_COUNT" -eq "$EXPECTED_MIRROR_EXCLUDED_TEST_COUNT" ]; then
        pass "E n=$ENTRY_COUNT registry entry count matches 2026-08-07 pinned constant"
    else
        fail "E n=$ENTRY_COUNT registry entry count differs from 2026-08-07 pinned constant expected=$EXPECTED_MIRROR_EXCLUDED_TEST_COUNT"
    fi
}

WORK_DIR="$(mktemp -d)"
CONTRACT_COMPLETED=0
cleanup() {
    local status=$?
    rm -rf "$WORK_DIR"
    # Fail closed: a mid-run abort (set -e/-u/pipefail) reaches this trap
    # before the summary and must never exit 0. Bash 3.2 resets $? for the
    # EXIT trap on such aborts, so a completion sentinel — not $? — decides.
    if [ "$CONTRACT_COMPLETED" != 1 ]; then
        exit 1
    fi
    exit "$status"
}
trap cleanup EXIT
ENTRY_COUNT=0
CONTENT_FILE=""

echo "=== mirror exclusion registry contract tests ==="
load_manifest
load_registry
load_debbie_sync_scope
write_mirror_absent_paths
check_entries_are_manifest_tests
check_declared_paths_are_referenced
check_declared_paths_are_mirror_absent
check_non_excluded_suites_are_clean
if [ "${FJCLOUD_MIRROR_CONTRACT_SKIP_REGRESSION:-0}" != 1 ]; then
    run_child_contract_fixture directory_reader "$(script_body '#!/usr/bin/env bash' 'test -d docs/private')" docs/private
    run_child_contract_fixture top_level_directory_reader "$(script_body '#!/usr/bin/env bash' 'test -d deliverables')" deliverables
    run_child_contract_fixture top_level_operand_reader "$(script_body '#!/usr/bin/env bash' 'rg needle deliverables')" deliverables
    run_child_contract_fixture continued_line_operand_reader "$(script_body '#!/usr/bin/env bash' "rg needle \\" 'deliverables')" deliverables
    run_child_contract_fixture prose_reader "$(script_body '#!/usr/bin/env bash' "printf '%s\n' 'deliverables are not a path operand here'")" accept
    run_child_contract_fixture heredoc_reader "$(script_body '#!/usr/bin/env bash' "cat > \"\$WORK_DIR/payload.txt\" <<'EOF'" "fixture prose \\" 'deliverables' 'EOF')" accept
    run_child_contract_fixture quoted_heredoc_text_reader "$(script_body '#!/usr/bin/env bash' "printf '%s\\n' 'example syntax: cat <<EOF'" 'test -d deliverables')" deliverables
    run_child_contract_fixture heredoc_dependency "$(script_body '#!/usr/bin/env bash' "python3 - <<'PY'" 'import pathlib' 'print(pathlib.Path("docs/private/specimen.txt").read_text())' 'PY')" docs/private/specimen.txt
    run_child_contract_fixture arithmetic_shift_reader "$(script_body '#!/usr/bin/env bash' "mask=\$(( 1 << bits ))" 'test -d deliverables')" deliverables
    run_child_contract_fixture vacuous_denominator '' vacuous
fi
check_entry_count_matches_pin
run_test_summary
CONTRACT_COMPLETED=1
