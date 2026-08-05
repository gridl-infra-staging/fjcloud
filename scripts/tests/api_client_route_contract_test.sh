#!/usr/bin/env bash
# Meta-test for the API client route contract checker.
# Stage 1 intentionally stays red until the checker is implemented in Stage 2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER_SCRIPT="$REPO_ROOT/scripts/canary/contracts/api_client_route_contract.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

FIXTURE_DIR="$(mktemp -d)"

cleanup() {
    if [[ -n "${FIXTURE_DIR:-}" && -d "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}
trap cleanup EXIT

CHECKER_OUTPUT=""
CHECKER_STATUS=0

run_checker() {
    local openapi_fixture="$1"
    shift

    if CHECKER_OUTPUT="$(bash "$CHECKER_SCRIPT" "$openapi_fixture" "$@" 2>&1)"; then
        CHECKER_STATUS=0
    else
        CHECKER_STATUS=$?
    fi
}

is_multiline_callsite_diagnostic() {
    local output="$1"
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *"undocumented route"* ]] || continue
        if [[ "$line" == *"destination-eligibility"* ]] \
            || [[ "$line" =~ multiline_interpolated_client\.ts(:|[[:space:]]+line[[:space:]]+)7([^0-9]|$) ]]; then
            return 0
        fi
    done <<< "$output"

    return 1
}

assert_multiline_callsite_identified() {
    local output="$1"
    local message="multiline failure should identify the second this.api(...) call site"

    if is_multiline_callsite_diagnostic "$output"; then
        pass "$message"
    else
        fail "$message (expected 'undocumented route' plus route suffix 'destination-eligibility' or source location 'multiline_interpolated_client.ts:7' in '$output')"
    fi
}

test_local_ci_registration_is_complete() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local manifest="$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"
    local gate_name="api-client-route-contract"

    assert_eq "$(grep -Fxc '#                    api-client-route-contract,' "$local_ci" || true)" "1" \
        "local-ci usage help names the API client route gate exactly once"
    assert_eq "$(grep -Fxc 'gate_api_client_route_contract() {' "$local_ci" || true)" "1" \
        "local-ci defines the API client route gate exactly once"
    assert_eq "$(grep -Fxc 'schedule api-client-route-contract' "$local_ci" || true)" "1" \
        "local-ci fast scheduler names the API client route gate exactly once"
    assert_eq \
        "$(grep -Fxc '            api-client-route-contract) run_gate api-client-route-contract gate_api_client_route_contract ;;' "$local_ci" || true)" \
        "1" \
        "local-ci dispatches the API client route gate exactly once"
    assert_eq "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" "1" \
        "local-ci summary-only inventory names the API client route gate exactly once"
    assert_eq "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" "1" \
        "local-ci unknown-gate help names the API client route gate exactly once"
    assert_eq "$(grep -Fxc '    "scripts/tests/api_client_route_contract_test.sh"' "$manifest" || true)" "1" \
        "test reachability manifest names the API client route meta-test exactly once"
}

test_local_ci_gate_delegation_is_canonical() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local index_gate_body api_gate_body meta_test_line checker_line

    index_gate_body="$(sed -n '/^gate_index_export_clientside_contract()/,/^}/p' "$local_ci")"
    api_gate_body="$(sed -n '/^gate_api_client_route_contract()/,/^}/p' "$local_ci")"

    assert_contains "$index_gate_body" 'scripts/canary/contracts/index_export_browser_path_probe_contract_test.sh' \
        "index export gate keeps its browser-path contract test"
    assert_not_contains "$index_gate_body" 'api_client_route_contract' \
        "index export gate no longer owns the API client route contract"
    assert_contains "$api_gate_body" 'scripts/tests/api_client_route_contract_test.sh' \
        "API client route gate runs the hermetic meta-test"
    assert_contains "$api_gate_body" 'scripts/canary/contracts/api_client_route_contract.sh' \
        "API client route gate runs the canonical checker"
    meta_test_line="$(printf '%s\n' "$api_gate_body" | grep -nF 'scripts/tests/api_client_route_contract_test.sh' | cut -d: -f1)"
    checker_line="$(printf '%s\n' "$api_gate_body" | grep -nF 'scripts/canary/contracts/api_client_route_contract.sh' | cut -d: -f1)"
    if [ "$meta_test_line" -lt "$checker_line" ]; then
        pass "API client route gate runs the meta-test before the real-repository checker"
    else
        fail "API client route gate must run the meta-test before the real-repository checker"
    fi
}

if is_multiline_callsite_diagnostic "parser failed at multiline_interpolated_client.ts:7"; then
    fail "generic parser location error must not prove multiline call-site extraction"
else
    pass "generic parser location error does not prove multiline call-site extraction"
fi
if is_multiline_callsite_diagnostic "parser failed near /migration/example/destination-eligibility"; then
    fail "generic parser route error must not prove multiline call-site extraction"
else
    pass "generic parser route error does not prove multiline call-site extraction"
fi
if is_multiline_callsite_diagnostic $'undocumented route: GET /migration/algolia/availability\nparser failed at multiline_interpolated_client.ts:7'; then
    fail "mixed unrelated diagnostics must not prove multiline call-site extraction"
else
    pass "mixed unrelated diagnostics do not prove multiline call-site extraction"
fi
if is_multiline_callsite_diagnostic $'undocumented route: GET /migration/algolia/availability\nundocumented route at multiline_interpolated_client.ts:7'; then
    pass "later qualifying multiline diagnostic proves multiline call-site extraction"
else
    fail "later qualifying multiline diagnostic should prove multiline call-site extraction"
fi
if is_multiline_callsite_diagnostic "undocumented route at multiline_interpolated_client.ts:7"; then
    pass "undocumented-route source location proves multiline call-site extraction"
else
    fail "undocumented-route source location should prove multiline call-site extraction"
fi
if is_multiline_callsite_diagnostic "undocumented route: POST /migration/{source_provider}/destination-eligibility"; then
    pass "undocumented normalized route proves multiline call-site extraction"
else
    fail "undocumented normalized route should prove multiline call-site extraction"
fi

missing_checker_openapi="$FIXTURE_DIR/missing_checker_openapi.json"
missing_checker_client="$FIXTURE_DIR/missing_checker_client.ts"
cat > "$missing_checker_openapi" <<'JSON'
{"openapi":"3.0.0","paths":{}}
JSON
cat > "$missing_checker_client" <<'TYPESCRIPT'
export class EmptyMigrationClient {}
TYPESCRIPT

if [[ ! -f "$CHECKER_SCRIPT" ]]; then
    run_checker "$missing_checker_openapi" "$missing_checker_client"
    printf 'MISSING_CHECKER_OUTPUT: %s\n' "$CHECKER_OUTPUT"
    assert_eq "$CHECKER_STATUS" "127" "missing checker should return shell status 127"
    assert_contains "$CHECKER_OUTPUT" "$CHECKER_SCRIPT" "missing checker output should name the checker path"
    assert_contains "$CHECKER_OUTPUT" "No such file or directory" "missing checker output should explain the missing file"
    fail "checker implementation missing: scripts/canary/contracts/api_client_route_contract.sh"
    cleanup
    trap - EXIT
    run_test_summary
fi

documented_openapi="$FIXTURE_DIR/documented_openapi.json"
neutral_openapi="$FIXTURE_DIR/neutral_openapi.json"
neutral_job_openapi="$FIXTURE_DIR/neutral_job_openapi.json"
field_contract_openapi="$FIXTURE_DIR/field_contract_openapi.json"
schema_less_openapi="$FIXTURE_DIR/schema_less_openapi.json"
schema_contract_anchor_client="$FIXTURE_DIR/schema_contract_anchor_client.ts"
undocumented_client="$FIXTURE_DIR/undocumented_client.ts"
wrong_method_client="$FIXTURE_DIR/wrong_method_client.ts"
neutral_documented_client="$FIXTURE_DIR/neutral_documented_client.ts"
neutral_wrong_method_client="$FIXTURE_DIR/neutral_wrong_method_client.ts"
neutral_literal_descendant_client="$FIXTURE_DIR/neutral_literal_descendant_client.ts"
vacuous_client="$FIXTURE_DIR/vacuous_client.ts"
pseudocall_client="$FIXTURE_DIR/pseudocall_client.ts"
regex_pseudocall_client="$FIXTURE_DIR/regex_pseudocall_client.ts"
too_few_args_client="$FIXTURE_DIR/too_few_args_client.ts"
dynamic_method_client="$FIXTURE_DIR/dynamic_method_client.ts"
dynamic_path_client="$FIXTURE_DIR/dynamic_path_client.ts"
dynamic_template_path_client="$FIXTURE_DIR/dynamic_template_path_client.ts"
generic_documented_client="$FIXTURE_DIR/generic_documented_client.ts"
multiline_interpolated_client="$FIXTURE_DIR/multiline_interpolated_client.ts"
documented_availability_client="$FIXTURE_DIR/documented_availability_client.ts"
commented_arguments_client="$FIXTURE_DIR/commented_arguments_client.ts"
documented_jobs_client="$FIXTURE_DIR/documented_jobs_client.ts"
literal_braces_client="$FIXTURE_DIR/literal_braces_client.ts"
non_target_receiver_client="$FIXTURE_DIR/non_target_receiver_client.ts"
property_chain_receiver_client="$FIXTURE_DIR/property_chain_receiver_client.ts"
ts_only_field_client="$FIXTURE_DIR/ts_only_field_client.ts"
schema_only_field_client="$FIXTURE_DIR/schema_only_field_client.ts"
aligned_and_skipped_interfaces_client="$FIXTURE_DIR/aligned_and_skipped_interfaces_client.ts"
zero_exported_interfaces_client="$FIXTURE_DIR/zero_exported_interfaces_client.ts"
all_interfaces_skipped_client="$FIXTURE_DIR/all_interfaces_skipped_client.ts"
field_name_only_client="$FIXTURE_DIR/field_name_only_client.ts"
nested_object_client="$FIXTURE_DIR/nested_object_client.ts"
readonly_property_client="$FIXTURE_DIR/readonly_property_client.ts"
extended_interface_client="$FIXTURE_DIR/extended_interface_client.ts"
generic_constraint_client="$FIXTURE_DIR/generic_constraint_client.ts"
same_line_properties_client="$FIXTURE_DIR/same_line_properties_client.ts"
function_member_client="$FIXTURE_DIR/function_member_client.ts"
method_signature_client="$FIXTURE_DIR/method_signature_client.ts"
generic_method_signature_client="$FIXTURE_DIR/generic_method_signature_client.ts"
index_signature_client="$FIXTURE_DIR/index_signature_client.ts"
malformed_method_signature_client="$FIXTURE_DIR/malformed_method_signature_client.ts"
literal_type_client="$FIXTURE_DIR/literal_type_client.ts"
newline_literal_type_client="$FIXTURE_DIR/newline_literal_type_client.ts"
multiline_type_annotation_client="$FIXTURE_DIR/multiline_type_annotation_client.ts"
quoted_property_client="$FIXTURE_DIR/quoted_property_client.ts"
readonly_named_field_client="$FIXTURE_DIR/readonly_named_field_client.ts"

cat > "$documented_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/migration/algolia/availability": {
      "get": {"responses": {"200": {"description": "available"}}}
    },
    "/migration/algolia/jobs": {
      "post": {"responses": {"202": {"description": "accepted"}}}
    },
    "/migration/algolia/jobs/{job_id}": {
      "get": {"responses": {"200": {"description": "found"}}}
    },
    "/fixture/schema-contract-anchor": {
      "get": {"responses": {"200": {"description": "fixture"}}}
    }
  },
  "components": {
    "schemas": {
      "RouteContractFixtureResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"}
        }
      }
    }
  }
}
JSON

cat > "$neutral_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/migration/{source_provider}/availability": {
      "get": {"responses": {"200": {"description": "available"}}}
    },
    "/fixture/schema-contract-anchor": {
      "get": {"responses": {"200": {"description": "fixture"}}}
    }
  },
  "components": {
    "schemas": {
      "RouteContractFixtureResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"}
        }
      }
    }
  }
}
JSON

cat > "$neutral_job_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/migration/{source_provider}/jobs/{id}": {
      "get": {"responses": {"200": {"description": "found"}}}
    }
  }
}
JSON

cat > "$schema_less_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/migration/algolia/availability": {
      "get": {"responses": {"200": {"description": "available"}}}
    }
  }
}
JSON

cat > "$schema_contract_anchor_client" <<'TYPESCRIPT'
export class SchemaContractAnchorClient {
  check() {
    return this.api('GET', '/fixture/schema-contract-anchor');
  }
}

export interface RouteContractFixtureResponse {
  id: string;
}
TYPESCRIPT

cat > "$field_contract_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/migration/algolia/availability": {
      "get": {"responses": {"200": {"description": "available"}}}
    }
  },
  "components": {
    "schemas": {
      "TsOnlyResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"}
        }
      },
      "SchemaOnlyResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "schema_only": {"type": "string"}
        }
      },
      "AlignedResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "status": {"type": "string"}
        }
      },
      "FieldNameOnlyResponse": {
        "type": "object",
        "required": ["id"],
        "properties": {
          "id": {"type": "string"},
          "status": {"type": "integer"}
        }
      },
      "NestedObjectResponse": {
        "type": "object",
        "properties": {
          "meta": {"type": "object"},
          "top_level": {"type": "string"}
        }
      },
      "ReadonlyPropertyResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "status": {"type": "string"}
        }
      },
      "ReadonlyNamedFieldResponse": {
        "type": "object",
        "properties": {
          "readonly": {"type": "string"}
        }
      },
      "ExtendedResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "status": {"type": "string"}
        }
      },
      "GenericConstraintResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"}
        }
      },
      "SameLinePropertiesResponse": {
        "type": "object",
        "properties": {
          "id": {"type": "string"},
          "status": {"type": "string"}
        }
      },
      "FunctionMemberResponse": {
        "type": "object",
        "properties": {
          "handler": {"type": "string"}
        }
      },
      "MethodSignatureResponse": {
        "type": "object",
        "properties": {
          "handler": {"type": "string"}
        }
      },
      "GenericMethodSignatureResponse": {
        "type": "object",
        "properties": {
          "handler": {"type": "string"}
        }
      },
      "IndexSignatureResponse": {
        "type": "object",
        "properties": {}
      },
      "LiteralTypeResponse": {
        "type": "object",
        "properties": {
          "status": {"type": "string"},
          "id": {"type": "string"}
        }
      },
      "NewlineLiteralTypeResponse": {
        "type": "object",
        "properties": {
          "status": {"type": "string"},
          "id": {"type": "string"}
        }
      },
      "MultilineTypeAnnotationResponse": {
        "type": "object",
        "properties": {
          "status": {"type": "string"},
          "id": {"type": "string"}
        }
      }
    }
  }
}
JSON

cat > "$undocumented_client" <<'TYPESCRIPT'
export class UndocumentedMigrationClient {
  check() {
    return this.api('GET', '/migration/algolia/archive');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$undocumented_client"
assert_ne "$CHECKER_STATUS" "0" "undocumented route should fail the checker"
assert_contains "$CHECKER_OUTPUT" "/migration/algolia/archive" "undocumented-route failure should name the missing path"

cat > "$wrong_method_client" <<'TYPESCRIPT'
export class WrongMethodMigrationClient {
  check() {
    return this.api('POST', '/migration/algolia/availability');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$wrong_method_client"
assert_ne "$CHECKER_STATUS" "0" "wrong HTTP method should fail the checker"
assert_contains "$CHECKER_OUTPUT" "method mismatch" "wrong-method failure should identify the defect as a method mismatch"
assert_contains "$CHECKER_OUTPUT" "POST" "method-mismatch failure should name the client method"
assert_contains "$CHECKER_OUTPUT" "/migration/algolia/availability" "method-mismatch failure should name the route path"

cat > "$neutral_documented_client" <<'TYPESCRIPT'
export class NeutralDocumentedMigrationClient {
  check(sourceProvider) {
    return this.api('GET', `/migration/${pathSegment(sourceProvider)}/availability`);
  }
}
TYPESCRIPT

run_checker "$neutral_openapi" "$neutral_documented_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "one neutral OpenAPI template should cover every SOURCE_PROVIDERS expansion"

cat > "$neutral_wrong_method_client" <<'TYPESCRIPT'
export class NeutralWrongMethodMigrationClient {
  check(sourceProvider) {
    return this.api('POST', `/migration/${pathSegment(sourceProvider)}/availability`);
  }
}
TYPESCRIPT

run_checker "$neutral_openapi" "$neutral_wrong_method_client"
assert_ne "$CHECKER_STATUS" "0" "wrong HTTP method should fail against a matching neutral OpenAPI template"
for source_provider in algolia meilisearch typesense; do
    assert_contains "$CHECKER_OUTPUT" \
        "method mismatch: POST /migration/$source_provider/availability" \
        "neutral-template method mismatch should report the $source_provider expansion"
done

cat > "$neutral_literal_descendant_client" <<'TYPESCRIPT'
export class NeutralLiteralDescendantClient {
  check() {
    return this.api('GET', '/migration/algolia/jobs/resume');
  }
}
TYPESCRIPT

run_checker "$neutral_job_openapi" "$neutral_literal_descendant_client"
assert_ne \
    "$CHECKER_STATUS" \
    "0" \
    "OpenAPI path parameters should not match arbitrary literal client segments"
assert_contains \
    "$CHECKER_OUTPUT" \
    "/migration/algolia/jobs/resume" \
    "literal-descendant failure should name the client route"

cat > "$vacuous_client" <<'TYPESCRIPT'
export class VacuousMigrationClient {
  check() {
    return fetch('/health');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$vacuous_client"
assert_ne "$CHECKER_STATUS" "0" "zero extracted this.api(...) call sites should fail closed"
assert_contains "$CHECKER_OUTPUT" "no this.api(...) call sites found" "vacuity failure should explicitly identify zero extracted call sites"

cat > "$pseudocall_client" <<'TYPESCRIPT'
export class PseudocallMigrationClient {
  check() {
    // return this.api('GET', '/migration/algolia/availability');
    const example = "this.api('POST', '/migration/algolia/jobs')";
    const template = `this.api('GET', '/migration/algolia/availability')`;
    return fetch('/health');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$pseudocall_client"
assert_ne "$CHECKER_STATUS" "0" "comments and strings containing this.api(...) should not count as call sites"
assert_contains "$CHECKER_OUTPUT" "no this.api(...) call sites found" "pseudo-call-only failure should identify zero executable call sites"

cat > "$regex_pseudocall_client" <<'TYPESCRIPT'
export class RegexPseudocallMigrationClient {
  check() {
    const pattern = /this.api(.*)/;
    return pattern.test('not a call site');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$regex_pseudocall_client"
assert_ne "$CHECKER_STATUS" "0" "regex literals containing this.api(...) should not count as call sites"
assert_contains "$CHECKER_OUTPUT" "no this.api(...) call sites found" "regex-only failure should identify zero executable call sites"

cat > "$too_few_args_client" <<'TYPESCRIPT'
export class TooFewArgsMigrationClient {
  check() {
    return this.api('GET');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$too_few_args_client"
assert_ne "$CHECKER_STATUS" "0" "this.api(...) with too few arguments should fail closed"
assert_contains "$CHECKER_OUTPUT" "unsupported this.api(...) call" "too-few-args failure should identify unsupported extraction"
assert_contains "$CHECKER_OUTPUT" "too_few_args_client.ts:3" "too-few-args failure should include file and line"

cat > "$dynamic_method_client" <<'TYPESCRIPT'
export class DynamicMethodMigrationClient {
  check(method) {
    return this.api(method, '/migration/algolia/availability');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$dynamic_method_client"
assert_ne "$CHECKER_STATUS" "0" "this.api(...) with a non-literal method should fail closed"
assert_contains "$CHECKER_OUTPUT" "unsupported this.api(...) call" "dynamic-method failure should identify unsupported extraction"
assert_contains "$CHECKER_OUTPUT" "dynamic_method_client.ts:3" "dynamic-method failure should include file and line"

cat > "$dynamic_path_client" <<'TYPESCRIPT'
export class DynamicPathMigrationClient {
  check(path) {
    return this.api('GET', path);
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$dynamic_path_client"
assert_ne "$CHECKER_STATUS" "0" "this.api(...) with a non-literal path should fail closed"
assert_contains "$CHECKER_OUTPUT" "unsupported this.api(...) call" "dynamic-path failure should identify unsupported extraction"
assert_contains "$CHECKER_OUTPUT" "dynamic_path_client.ts:3" "dynamic-path failure should include file and line"

cat > "$dynamic_template_path_client" <<'TYPESCRIPT'
export class DynamicTemplatePathMigrationClient {
  check(suffix) {
    return this.api('GET', `/migration/algolia/jobs${suffix}`);
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$dynamic_template_path_client"
assert_ne "$CHECKER_STATUS" "0" "this.api(...) with dynamic template path content should fail closed"
assert_contains "$CHECKER_OUTPUT" "unsupported this.api(...) call" "dynamic-template-path failure should identify unsupported extraction"
assert_contains "$CHECKER_OUTPUT" "dynamic_template_path_client.ts:3" "dynamic-template-path failure should include file and line"

cat > "$generic_documented_client" <<'TYPESCRIPT'
export class GenericDocumentedClient {
  check() {
    return this.api<Promise<string>>('GET', '/migration/algolia/availability');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$generic_documented_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "generic this.api<T>(...) call sites should still be extracted and compared"

cat > "$multiline_interpolated_client" <<'TYPESCRIPT'
export class MultilineInterpolatedMigrationClient {
  checkAvailability() {
    return this.api('GET', '/migration/algolia/availability');
  }

  checkDestination(sourceProvider, request) {
    return this.api(
      'POST',
      `/migration/${pathSegment(sourceProvider)}/destination-eligibility`,
      request
    );
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$multiline_interpolated_client"
assert_ne "$CHECKER_STATUS" "0" "undocumented multiline interpolated this.api(...) call site should be extracted"
assert_multiline_callsite_identified "$CHECKER_OUTPUT"

cat > "$documented_availability_client" <<'TYPESCRIPT'
export class DocumentedAvailabilityClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}
TYPESCRIPT
cat > "$commented_arguments_client" <<'TYPESCRIPT'
export class CommentedArgumentsClient {
  check() {
    return this.api(
      'GET',
      /* A closing parenthesis and comma here are not executable syntax: ), */
      '/migration/algolia/availability'
    );
  }
}
TYPESCRIPT
cat > "$documented_jobs_client" <<'TYPESCRIPT'
export class DocumentedJobsClient {
  create() {
    return this.api('POST', '/migration/algolia/jobs');
  }
}
TYPESCRIPT

run_checker \
    "$documented_openapi" \
    "$documented_availability_client" \
    "$documented_jobs_client" \
    "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "fully documented routes across multiple client files should pass"

run_checker "$documented_openapi" "$commented_arguments_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "comments inside a documented this.api(...) argument list should be ignored"

cat > "$literal_braces_client" <<'TYPESCRIPT'
export class LiteralBracesClient {
  fetchJob() {
    return this.api('GET', '/migration/algolia/jobs/{id}');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$literal_braces_client"
assert_ne "$CHECKER_STATUS" "0" "literal OpenAPI-style braces in a client route should fail closed"
assert_contains "$CHECKER_OUTPUT" "literal braces in client route path" "literal-braces failure should identify the unsupported runtime path"
assert_contains "$CHECKER_OUTPUT" "literal_braces_client.ts:3" "literal-braces failure should include file and line"

cat > "$non_target_receiver_client" <<'TYPESCRIPT'
export class NonTargetReceiverClient {
  check() {
    return otherthis.api('GET', '/migration/algolia/availability');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$non_target_receiver_client"
assert_ne "$CHECKER_STATUS" "0" "a non-target receiver ending in this should not count as this.api(...)"
assert_contains "$CHECKER_OUTPUT" "no this.api(...) call sites found" "non-target receivers should preserve the per-file vacuity failure"

cat > "$property_chain_receiver_client" <<'TYPESCRIPT'
export class PropertyChainReceiverClient {
  check(client) {
    return client.this.api('GET', '/migration/algolia/availability');
  }
}
TYPESCRIPT

run_checker "$documented_openapi" "$property_chain_receiver_client"
assert_ne "$CHECKER_STATUS" "0" "a property-chain receiver named this should not count as this.api(...)"
assert_contains "$CHECKER_OUTPUT" "no this.api(...) call sites found" "property-chain receivers should preserve the per-file vacuity failure"

cat > "$ts_only_field_client" <<'TYPESCRIPT'
export class TsOnlyFieldClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface TsOnlyResponse {
  id: string;
  ts_only: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$ts_only_field_client"
assert_ne "$CHECKER_STATUS" "0" "same-named interface field absent from schema should fail the checker"
assert_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: TsOnlyResponse" "TS-only field mismatch should name the interface"
assert_contains "$CHECKER_OUTPUT" "TS-only=['ts_only']" "TS-only field mismatch should list only the TypeScript-only field"
assert_contains "$CHECKER_OUTPUT" "schema-only=[]" "TS-only field mismatch should pin the empty schema-only list"

cat > "$schema_only_field_client" <<'TYPESCRIPT'
export class SchemaOnlyFieldClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface SchemaOnlyResponse {
  id: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$schema_only_field_client"
assert_ne "$CHECKER_STATUS" "0" "same-named schema field absent from interface should fail the checker"
assert_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: SchemaOnlyResponse" "schema-only field mismatch should name the interface"
assert_contains "$CHECKER_OUTPUT" "TS-only=[]" "schema-only field mismatch should pin the empty TypeScript-only list"
assert_contains "$CHECKER_OUTPUT" "schema-only=['schema_only']" "schema-only field mismatch should list only the schema-only field"

cat > "$aligned_and_skipped_interfaces_client" <<'TYPESCRIPT'
export class AlignedAndSkippedInterfacesClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface AlignedResponse {
  id: string;
  status: string;
}

export interface NoMatchingSchemaResponse {
  ignored: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$aligned_and_skipped_interfaces_client"
assert_eq "$CHECKER_STATUS" "0" "matching interface plus unmatched interface should pass when one schema is checked"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=1 total=2" "matching interface success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch" "matching interface success should not report field mismatches"
# The skipped interface may legitimately appear in operator-visible skip logging;
# only mismatch reporting for it is forbidden.
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: NoMatchingSchemaResponse" "skipped unmatched interface should not be reported as a mismatch"

cat > "$zero_exported_interfaces_client" <<'TYPESCRIPT'
export class ZeroExportedInterfacesClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$zero_exported_interfaces_client"
assert_ne "$CHECKER_STATUS" "0" "zero exported TypeScript interfaces should fail the schema field contract"
assert_contains "$CHECKER_OUTPUT" "no exported TypeScript interfaces found for schema contract" "zero-interface failure should name the vacuity defect"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=0 skipped=0 total=0" "zero-interface failure should pin total=0 summary"

run_checker "$schema_less_openapi" "$zero_exported_interfaces_client"
assert_ne "$CHECKER_STATUS" "0" "zero exported interfaces should fail when components.schemas is absent"
assert_contains "$CHECKER_OUTPUT" "no exported TypeScript interfaces found for schema contract" "schema-less zero-interface failure should name the vacuity defect"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=0 skipped=0 total=0" "schema-less zero-interface failure should pin total=0 summary"

cat > "$all_interfaces_skipped_client" <<'TYPESCRIPT'
export class AllInterfacesSkippedClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface NoMatchingSchemaResponse {
  ignored: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$all_interfaces_skipped_client"
assert_ne "$CHECKER_STATUS" "0" "only schema-unmatched interfaces should fail the schema field contract"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check checked == 0; refusing vacuous success" "all-skipped failure should name the checked == 0 vacuity defect"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=0 skipped=1 total=1" "all-skipped failure should pin checked/skipped/total summary"

run_checker "$schema_less_openapi" "$all_interfaces_skipped_client"
assert_ne "$CHECKER_STATUS" "0" "all interfaces should count as skipped when components.schemas is absent"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check checked == 0; refusing vacuous success" "schema-less all-skipped failure should name the checked == 0 vacuity defect"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=0 skipped=1 total=1" "schema-less all-skipped failure should pin checked/skipped/total summary"

# Field-name-only success specimen: the interface and its same-named schema share
# an identical property-NAME set but disagree on optionality and primitive types.
# The contract compares field-name sets only, so this must pass; an overconstrained
# Stage 2 implementation that compares requiredness or value types would wrongly fail.
cat > "$field_name_only_client" <<'TYPESCRIPT'
export class FieldNameOnlyClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface FieldNameOnlyResponse {
  id?: number;
  status: boolean;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$field_name_only_client"
assert_eq "$CHECKER_STATUS" "0" "identical field names with differing optionality and primitive types should pass"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "field-name-only success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch" "field-name-only success must not report a mismatch on optionality or type differences"

# Nested inline-object specimen: a nested object body closes with an inner brace,
# then a top-level field follows after that closing brace. The correct top-level
# field-name set is {meta, top_level}. The explicitly forbidden non-greedy
# interface-body regex would stop at the first (inner) closing brace and extract
# {meta, inner}, producing TS-only=['inner'] / schema-only=['top_level'] and a
# mismatch. Asserting success proves brace-balanced parsing.
cat > "$nested_object_client" <<'TYPESCRIPT'
export class NestedObjectClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface NestedObjectResponse {
  meta: {
    inner: string;
  };
  top_level: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$nested_object_client"
assert_eq "$CHECKER_STATUS" "0" "nested inline object with a trailing top-level field should pass on top-level field names"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "nested-object success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: NestedObjectResponse" "non-greedy interface-body parsing that captures 'inner' as a top-level field must not satisfy the contract"

cat > "$readonly_property_client" <<'TYPESCRIPT'
export class ReadonlyPropertyClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface ReadonlyPropertyResponse {
  readonly id: string;
  status: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$readonly_property_client"
assert_eq "$CHECKER_STATUS" "0" "readonly interface properties should participate in field-name parity"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "readonly-property success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "schema-only=['id']" "readonly-property success must not drop the readonly field"

cat > "$extended_interface_client" <<'TYPESCRIPT'
export class ExtendedInterfaceClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface ExtendedResponse extends BaseFields {
  id: string;
  status: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$extended_interface_client"
assert_eq "$CHECKER_STATUS" "0" "interfaces with extends clauses should participate in field-name parity"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "extended-interface success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "no exported TypeScript interfaces found for schema contract" "extended-interface success must not be treated as zero-interface vacuity"

cat > "$generic_constraint_client" <<'TYPESCRIPT'
export class GenericConstraintClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface GenericConstraintResponse<T extends { id: string }> {
  status: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$generic_constraint_client"
assert_ne "$CHECKER_STATUS" "0" "object type inside a generic constraint must not be mistaken for the interface body"
assert_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: GenericConstraintResponse TS-only=['status'] schema-only=['id']" "generic-constraint parsing must compare the real body field 'status' against schema field 'id'"

cat > "$same_line_properties_client" <<'TYPESCRIPT'
export class SameLinePropertiesClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface SameLinePropertiesResponse { id: string; status: string; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$same_line_properties_client"
assert_eq "$CHECKER_STATUS" "0" "same-line interface properties should participate in field-name parity"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "same-line-properties success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: SameLinePropertiesResponse" "same-line-properties success must not drop later semicolon-separated fields"

cat > "$function_member_client" <<'TYPESCRIPT'
export class FunctionMemberClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface FunctionMemberResponse { handler: (request: Request) => Promise<void>; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$function_member_client"
assert_eq "$CHECKER_STATUS" "0" "same-line function-valued interface members should participate by property name only"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "function-member success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: FunctionMemberResponse" "function-member success must not treat typed parameter names as top-level fields"

cat > "$method_signature_client" <<'TYPESCRIPT'
export class MethodSignatureClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface MethodSignatureResponse { handler(request: Request): Promise<void>; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$method_signature_client"
assert_eq "$CHECKER_STATUS" "0" "method-signature interface members should participate by member name only"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "method-signature success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: MethodSignatureResponse" "method-signature success must not treat typed parameter names as top-level fields"

cat > "$generic_method_signature_client" <<'TYPESCRIPT'
export class GenericMethodSignatureClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface GenericMethodSignatureResponse { handler<T>(request: T): Promise<void>; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$generic_method_signature_client"
assert_eq "$CHECKER_STATUS" "0" "generic method-signature interface members should participate by member name only"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "generic-method-signature success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: GenericMethodSignatureResponse" "generic-method-signature success must not treat typed parameter names as top-level fields"

cat > "$index_signature_client" <<'TYPESCRIPT'
export class IndexSignatureClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface IndexSignatureResponse { [key: string]: unknown; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$index_signature_client"
assert_eq "$CHECKER_STATUS" "0" "index signatures should not contribute named fields to schema parity"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "index-signature success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: IndexSignatureResponse" "index-signature success must not treat the index parameter as a top-level field"

cat > "$malformed_method_signature_client" <<'TYPESCRIPT'
export class MalformedMethodSignatureClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface MethodSignatureResponse { handler(request: Request: Promise<void>; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$malformed_method_signature_client"
assert_ne "$CHECKER_STATUS" "0" "unclosed interface method parameter lists should fail closed"
assert_contains "$CHECKER_OUTPUT" "unclosed interface method parameter list" "unclosed interface method parameter diagnostic should name the interface construct"
assert_not_contains "$CHECKER_OUTPUT" "unclosed this.api(...) call" "unclosed interface method parameter diagnostic must not blame route call parsing"

# Literal-only property type specimen: a property whose entire type is a masked
# literal (e.g. `status: 'ok'`) leaves no surviving non-whitespace token after
# masking. The `;` after it is the real member delimiter, so the following `id`
# field must still be extracted. A `skip_type_annotation` that only stops on a
# delimiter once it has seen a type token would swallow `id` and report a false
# schema-only=['id'] mismatch.
cat > "$literal_type_client" <<'TYPESCRIPT'
export class LiteralTypeClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface LiteralTypeResponse { status: 'ok'; id: string; }
TYPESCRIPT

run_checker "$field_contract_openapi" "$literal_type_client"
assert_eq "$CHECKER_STATUS" "0" "a literal-only property type must not swallow following interface members"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "literal-type success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: LiteralTypeResponse" "literal-type success must not drop the field following a masked literal annotation"

# Newline-delimited literal-only property type specimen: semicolons are optional
# between interface members. The masked literal must count as type content on its
# line so the following `id` member is not consumed as part of `status`'s type.
cat > "$newline_literal_type_client" <<'TYPESCRIPT'
export class NewlineLiteralTypeClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface NewlineLiteralTypeResponse {
  status: 'ok'
  id: string
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$newline_literal_type_client"
assert_eq "$CHECKER_STATUS" "0" "a newline-delimited literal-only property type must not swallow the following member"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "newline-literal-type success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "schema-only=['id']" "newline-literal-type success must not drop the field following a masked literal annotation"

# A newline immediately after `:` begins a multiline type annotation; it is not
# a member delimiter. This guards the distinction the literal-presence fix must
# preserve while accepting semicolon-free members.
cat > "$multiline_type_annotation_client" <<'TYPESCRIPT'
export class MultilineTypeAnnotationClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface MultilineTypeAnnotationResponse {
  status:
    string
  id: string
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$multiline_type_annotation_client"
assert_eq "$CHECKER_STATUS" "0" "a type on the line after its colon must remain part of the preceding property"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "multiline-type-annotation success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: MultilineTypeAnnotationResponse" "multiline-type-annotation success must not reinterpret the type name as a property"

# Quoted property-name specimen: a quoted member such as `"ignored": string` is
# legal TypeScript but is not an identifier field, so identifier-only extraction
# must skip it entirely. The literal-presence marker kept for masked-literal type
# detection must not be identifier-shaped; otherwise the masked quote opener is
# read back as a phantom field (previously `_`) and reported as a false TS-only
# mismatch on valid declarations.
cat > "$quoted_property_client" <<'TYPESCRIPT'
export class QuotedPropertyClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface AlignedResponse {
  "ignored": string;
  id: string;
  status: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$quoted_property_client"
assert_eq "$CHECKER_STATUS" "0" "a quoted property name must not become a phantom identifier field"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "quoted-property success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "interface/schema field mismatch: AlignedResponse" "quoted-property success must not report a mismatch from a masked literal-presence marker"

cat > "$readonly_named_field_client" <<'TYPESCRIPT'
export class ReadonlyNamedFieldClient {
  check() {
    return this.api('GET', '/migration/algolia/availability');
  }
}

export interface ReadonlyNamedFieldResponse {
  readonly: string;
}
TYPESCRIPT

run_checker "$field_contract_openapi" "$readonly_named_field_client"
assert_eq "$CHECKER_STATUS" "0" "a legal field literally named readonly must not be dropped as a modifier"
assert_contains "$CHECKER_OUTPUT" "interface/schema field check: checked=1 skipped=0 total=1" "readonly-named-field success should pin checked/skipped/total summary"
assert_not_contains "$CHECKER_OUTPUT" "schema-only=['readonly']" "readonly-named-field success must not misread the field name as a modifier"

# --- Stage 3: client_paths.ts builder resolution + widened corpus gate ---
# These fixtures exercise this.api(...) call sites whose path argument is a
# client_paths.ts builder call (indexPath/experimentPath/dictionaryPath), a
# query-suffix builder (buildQueryString/this.analyticsQuery), a pathSegment
# dynamic segment, or an internal-only exempted route. The checker resolves the
# builders by reading the REAL web/src/lib/api/client_paths.ts from repo_root,
# exactly as load_provider_literals reads the real types file in fixture mode.

path_builder_openapi="$FIXTURE_DIR/path_builder_openapi.json"
query_suffix_openapi="$FIXTURE_DIR/query_suffix_openapi.json"
dynamic_segment_openapi="$FIXTURE_DIR/dynamic_segment_openapi.json"
exemption_openapi="$FIXTURE_DIR/exemption_openapi.json"
path_builder_synonyms_client="$FIXTURE_DIR/path_builder_synonyms_client.ts"
path_builder_documented_client="$FIXTURE_DIR/path_builder_documented_client.ts"
path_builder_wrong_method_client="$FIXTURE_DIR/path_builder_wrong_method_client.ts"
query_suffix_documented_client="$FIXTURE_DIR/query_suffix_documented_client.ts"
query_suffix_undocumented_client="$FIXTURE_DIR/query_suffix_undocumented_client.ts"
dynamic_segment_documented_client="$FIXTURE_DIR/dynamic_segment_documented_client.ts"
dynamic_segment_wrong_index_client="$FIXTURE_DIR/dynamic_segment_wrong_index_client.ts"
exempted_route_client="$FIXTURE_DIR/exempted_route_client.ts"
non_exempt_internal_client="$FIXTURE_DIR/non_exempt_internal_client.ts"
zero_callsite_client="$FIXTURE_DIR/zero_callsite_client.ts"

cat > "$path_builder_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/indexes/{indexName}/synonyms": {
      "get": {"responses": {"200": {"description": "ok"}}}
    },
    "/indexes/{indexName}/experiments/{id}": {
      "get": {"responses": {"200": {"description": "ok"}}}
    },
    "/indexes/{indexName}/dictionaries/{dictionaryName}/batch": {
      "post": {"responses": {"200": {"description": "ok"}}}
    },
    "/fixture/schema-contract-anchor": {
      "get": {"responses": {"200": {"description": "fixture"}}}
    }
  },
  "components": {
    "schemas": {
      "RouteContractFixtureResponse": {
        "type": "object",
        "properties": {"id": {"type": "string"}}
      }
    }
  }
}
JSON

cat > "$query_suffix_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/usage": {"get": {"responses": {"200": {"description": "ok"}}}},
    "/indexes/{indexName}/analytics/searches": {
      "get": {"responses": {"200": {"description": "ok"}}}
    },
    "/fixture/schema-contract-anchor": {
      "get": {"responses": {"200": {"description": "fixture"}}}
    }
  },
  "components": {
    "schemas": {
      "RouteContractFixtureResponse": {
        "type": "object",
        "properties": {"id": {"type": "string"}}
      }
    }
  }
}
JSON

cat > "$dynamic_segment_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/indexes/{indexName}/objects/{objectID}": {
      "get": {"responses": {"200": {"description": "ok"}}}
    },
    "/indexes/{indexName}/rules/detail": {
      "get": {"responses": {"200": {"description": "ok"}}}
    },
    "/fixture/schema-contract-anchor": {
      "get": {"responses": {"200": {"description": "fixture"}}}
    }
  },
  "components": {
    "schemas": {
      "RouteContractFixtureResponse": {
        "type": "object",
        "properties": {"id": {"type": "string"}}
      }
    }
  }
}
JSON

cat > "$exemption_openapi" <<'JSON'
{
  "openapi": "3.0.0",
  "paths": {
    "/fixture/schema-contract-anchor": {
      "get": {"responses": {"200": {"description": "fixture"}}}
    }
  },
  "components": {
    "schemas": {
      "RouteContractFixtureResponse": {
        "type": "object",
        "properties": {"id": {"type": "string"}}
      }
    }
  }
}
JSON

# Group 1 red-first specimen (now the green target): before builder resolution
# landed, this failed with "path argument must be a string or template literal"
# because indexPath(...) is a call expression, not a string/template literal.
cat > "$path_builder_synonyms_client" <<'TYPESCRIPT'
export class PathBuilderSynonymsClient {
  clearSynonyms(indexName) {
    return this.api('GET', indexPath(indexName, '/synonyms'));
  }
}
TYPESCRIPT

run_checker "$path_builder_openapi" "$path_builder_synonyms_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "indexPath(...) path builder must resolve to a documented /indexes/{} route"
assert_not_contains "$CHECKER_OUTPUT" "path argument must be a string or template literal" "resolved builder call must not be reported as an unsupported non-literal path"

cat > "$path_builder_documented_client" <<'TYPESCRIPT'
export class PathBuilderDocumentedClient {
  getSynonyms(indexName) {
    return this.api('GET', indexPath(indexName, '/synonyms'));
  }
  getExperiment(indexName, id) {
    return this.api('GET', experimentPath(indexName, id));
  }
  batchDictionary(indexName, dictionaryName, body) {
    return this.api('POST', dictionaryPath(indexName, dictionaryName, '/batch'), body);
  }
}
TYPESCRIPT

run_checker "$path_builder_openapi" "$path_builder_documented_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "indexPath/experimentPath/dictionaryPath must all resolve to documented routes"
assert_not_contains "$CHECKER_OUTPUT" "undocumented route" "documented path-builder call sites must not be reported as undocumented"

cat > "$path_builder_wrong_method_client" <<'TYPESCRIPT'
export class PathBuilderWrongMethodClient {
  clearSynonyms(indexName) {
    return this.api('POST', indexPath(indexName, '/synonyms'));
  }
}
TYPESCRIPT

run_checker "$path_builder_openapi" "$path_builder_wrong_method_client" "$schema_contract_anchor_client"
assert_ne "$CHECKER_STATUS" "0" "wrong method on a resolved builder route must fail closed"
assert_contains "$CHECKER_OUTPUT" "method mismatch" "resolved builder wrong-method failure should be a method mismatch"
assert_contains "$CHECKER_OUTPUT" "POST" "resolved builder method-mismatch failure should name the client method"
assert_contains "$CHECKER_OUTPUT" "/indexes/{}/synonyms" "resolved builder failure must print the resolved /indexes/{} path, proving resolution reports the call site"

cat > "$query_suffix_documented_client" <<'TYPESCRIPT'
export class QuerySuffixDocumentedClient {
  getUsage(month) {
    return this.api('GET', `/usage${buildQueryString([['month', month]])}`);
  }
  getAnalyticsSearches(indexName, params) {
    return this.api('GET', indexPath(indexName, `/analytics/searches${this.analyticsQuery(params)}`));
  }
}
TYPESCRIPT

run_checker "$query_suffix_openapi" "$query_suffix_documented_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "buildQueryString/analyticsQuery suffixes with no literal ? must normalize to the base route"
assert_not_contains "$CHECKER_OUTPUT" "unsupported template interpolation" "query-builder suffixes must not raise unsupported-interpolation"

cat > "$query_suffix_undocumented_client" <<'TYPESCRIPT'
export class QuerySuffixUndocumentedClient {
  getMissing(month) {
    return this.api('GET', `/nonexistent${buildQueryString([['month', month]])}`);
  }
}
TYPESCRIPT

run_checker "$query_suffix_openapi" "$query_suffix_undocumented_client" "$schema_contract_anchor_client"
assert_ne "$CHECKER_STATUS" "0" "an undocumented route behind a query-builder suffix must still fail closed"
assert_contains "$CHECKER_OUTPUT" "/nonexistent" "query-suffix normalization must not swallow the undocumented base route"

cat > "$dynamic_segment_documented_client" <<'TYPESCRIPT'
export class DynamicSegmentDocumentedClient {
  getObject(indexName, objectID) {
    return this.api('GET', indexPath(indexName, `/objects/${pathSegment(objectID)}`));
  }
}
TYPESCRIPT

run_checker "$dynamic_segment_openapi" "$dynamic_segment_documented_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "a pathSegment(...) inside a builder suffix must match an OpenAPI {} at the same segment index"
assert_not_contains "$CHECKER_OUTPUT" "undocumented route" "correctly-indexed dynamic segment must not be reported as undocumented"

cat > "$dynamic_segment_wrong_index_client" <<'TYPESCRIPT'
export class DynamicSegmentWrongIndexClient {
  getRule(indexName, objectID) {
    return this.api('GET', indexPath(indexName, `/rules/${pathSegment(objectID)}`));
  }
}
TYPESCRIPT

run_checker "$dynamic_segment_openapi" "$dynamic_segment_wrong_index_client" "$schema_contract_anchor_client"
assert_ne "$CHECKER_STATUS" "0" "a placeholder where the documented route has a literal segment must fail closed"
assert_contains "$CHECKER_OUTPUT" "/indexes/{}/rules/{}" "segment-index mismatch failure must print the resolved client route"

cat > "$exempted_route_client" <<'TYPESCRIPT'
export class ExemptedRouteClient {
  getInternalRegions() {
    return this.api('GET', '/internal/regions');
  }
}
TYPESCRIPT

run_checker "$exemption_openapi" "$exempted_route_client" "$schema_contract_anchor_client"
assert_eq "$CHECKER_STATUS" "0" "GET /internal/regions must pass under the internal-only exemption"
assert_contains "$CHECKER_OUTPUT" "route exemption applied: GET /internal/regions" "exemption application should be reported for traceability"
assert_not_contains "$CHECKER_OUTPUT" "undocumented route: GET /internal/regions" "an exempted route must not be reported as undocumented"
assert_contains "$CHECKER_OUTPUT" "raw_hits=1" "the exemption specimen must count the pre-triage route hit"
assert_contains "$CHECKER_OUTPUT" "triaged_real=0" "the exemption specimen must not classify the false positive as real"
assert_contains "$CHECKER_OUTPUT" "triaged_false_positive=1" "the exemption specimen must count its explained false positive"

cat > "$non_exempt_internal_client" <<'TYPESCRIPT'
export class NonExemptInternalClient {
  getSecret() {
    return this.api('GET', '/internal/not-exempt');
  }
}
TYPESCRIPT

run_checker "$exemption_openapi" "$non_exempt_internal_client" "$schema_contract_anchor_client"
assert_ne "$CHECKER_STATUS" "0" "an undocumented route absent from the exemption list must still fail closed"
assert_contains "$CHECKER_OUTPUT" "undocumented route: GET /internal/not-exempt" "a non-exempt undocumented route must be reported"
assert_contains "$CHECKER_OUTPUT" "raw_hits=1" "the undocumented-route specimen must count the pre-triage route hit"
assert_contains "$CHECKER_OUTPUT" "triaged_real=1" "the undocumented-route specimen must classify the hit as real"
assert_contains "$CHECKER_OUTPUT" "triaged_false_positive=0" "the undocumented-route specimen must not classify the hit as a false positive"

# The exemption list is the single explicit owner; pin its exact size and contents
# so widening it later is a deliberate, reviewable edit and never silent drift.
assert_eq "$(grep -cE '^[[:space:]]*\("[A-Z]+", "/[^"]*"\): \($' "$CHECKER_SCRIPT" || true)" "1" \
    "ROUTE_EXEMPTIONS must contain exactly one entry"
assert_eq "$(grep -Fc '("GET", "/internal/regions"): (' "$CHECKER_SCRIPT" || true)" "1" \
    "ROUTE_EXEMPTIONS must contain exactly the GET /internal/regions entry"

# Denominator meta-tests: the gate must print a real denominator, name both
# production client files exactly once in no-argument mode, and refuse to pass
# vacuously when zero call sites are parsed.
assert_contains "$CHECKER_OUTPUT" "route contract denominator:" "the gate must print a denominator on every run"
assert_contains "$CHECKER_OUTPUT" "client_files=" "the denominator must report the client-file count"
assert_contains "$CHECKER_OUTPUT" "call_sites=" "the denominator must report the this.api(...) call-site count"
assert_contains "$CHECKER_OUTPUT" "raw_hits=" "the denominator must report route candidates before triage"
assert_contains "$CHECKER_OUTPUT" "triaged_real=" "the denominator must report real route violations"
assert_contains "$CHECKER_OUTPUT" "triaged_false_positive=" "the denominator must report explained false positives"
assert_eq "$(grep -Fc '"$REPO_ROOT/web/src/lib/api/migration_client.ts"' "$CHECKER_SCRIPT" || true)" "1" \
    "no-argument production mode must name migration_client.ts exactly once"
assert_eq "$(grep -Fc '"$REPO_ROOT/web/src/lib/api/client.ts"' "$CHECKER_SCRIPT" || true)" "1" \
    "no-argument production mode must name client.ts exactly once"

cat > "$zero_callsite_client" <<'TYPESCRIPT'
export class ZeroCallsiteClient {
  noop() {
    return fetch('/health');
  }
}
TYPESCRIPT

run_checker "$path_builder_openapi" "$zero_callsite_client"
assert_ne "$CHECKER_STATUS" "0" "a run that parses zero call sites must exit non-zero, not pass vacuously"
assert_contains "$CHECKER_OUTPUT" "call_sites=0" "the denominator must expose the zero parsed call sites"

test_local_ci_registration_is_complete
test_local_ci_gate_delegation_is_canonical

cleanup
trap - EXIT
run_test_summary
