#!/usr/bin/env bash
# Shared test helper for mocking cargo invocations in gate script tests.

set -euo pipefail

setup_mock_cargo() {
    local mock_dir="$1" behavior="${2:-pass}"
    cat > "$mock_dir/cargo" <<MOCK
#!/usr/bin/env bash
echo "cargo invoked cwd=\$PWD integration=\${INTEGRATION:-unset}" >> "$mock_dir/cargo_invocations.log"
echo "cargo args=\$*" >> "$mock_dir/cargo_invocations.log"
if [ "$behavior" = "fail" ]; then
    echo "test result: FAILED" >&2
    exit 1
fi
echo "test result: ok. 3 passed; 0 failed"
exit 0
MOCK
    chmod +x "$mock_dir/cargo"
}
