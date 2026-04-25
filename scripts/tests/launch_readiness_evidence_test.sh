#!/usr/bin/env bash
# Contract tests for the launch-readiness evidence bundle docs.
#
# This suite focuses on the parts that are easy to regress when docs drift:
# discoverability, canonical cross-links, safe filename conventions, and
# protection against accidentally checking secret-looking values into prose.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVIDENCE_FILE="$REPO_ROOT/docs/runbooks/launch_readiness_evidence_20260420.md"
READINESS_DOC="$REPO_ROOT/docs/LOCAL_LAUNCH_READINESS.md"
ROADMAP_DOC="$REPO_ROOT/ROADMAP.md"
PRIORITIES_DOC="$REPO_ROOT/PRIORITIES.md"
GAPS_AND_RISKS_DOC="$REPO_ROOT/docs/checklists/apr21_pm_2_post_phase6_gaps_and_risks.md"
STAGING_EVIDENCE_DOC="$REPO_ROOT/docs/runbooks/staging-evidence.md"
SES_DELIVERABILITY_BOUNDARY_PROOF_ARTIFACT="$REPO_ROOT/docs/runbooks/evidence/ses-deliverability/20260423T202158Z_ses_boundary_proof_full.txt"
SES_BOUNDARY_PROOF_RECONCILIATION="$REPO_ROOT/docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md"
BETA_CHECKLIST_DOC="$REPO_ROOT/docs/runbooks/beta_launch_readiness.md"
STAGE1_OWNER_MAP_CHECKLIST="/Users/stuart/.matt/projects/fjcloud_dev-c1b01a59/apr24_1pm_t1_4_beta_launch_readiness_doc.md-1ea79f64/checklists/stage_01_checklist.md"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

load_beta_checklist_content() {
    if [ ! -f "$BETA_CHECKLIST_DOC" ]; then
        return 1
    fi
    cat "$BETA_CHECKLIST_DOC"
}

beta_checklist_section_line_number() {
    local heading="$1"
    awk -v heading="$heading" '$0 == heading { print NR; exit }' "$BETA_CHECKLIST_DOC"
}

to_ascii_lower() {
    LC_ALL=C printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

owner_resolves_to_stage1_class() {
    local owner_value="$1"
    local stage1_owner_map_content="$2"
    local normalized_owner owner_lower
    normalized_owner="$(printf '%s' "$owner_value" | sed -E 's/`//g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
    owner_lower="$(to_ascii_lower "$normalized_owner")"

    if [[ "$owner_lower" == external-owner:* || "$owner_lower" == external\ owner:* ]]; then
        return 0
    fi

    local owner_paths
    owner_paths="$(printf '%s\n' "$normalized_owner" | grep -oE '(ROADMAP\.md|PRIORITIES\.md|docs/[A-Za-z0-9_./+-]+|scripts/[A-Za-z0-9_./+-]+|ops/[A-Za-z0-9_./+-]+|chats/icg/[A-Za-z0-9_./+-]+|web/[A-Za-z0-9_./+-]+|infra/[A-Za-z0-9_./+-]+)' || true)"
    if [ -z "$owner_paths" ]; then
        return 1
    fi

    local owner_path
    while IFS= read -r owner_path; do
        if [ -z "$owner_path" ]; then
            continue
        fi
        if [[ "$stage1_owner_map_content" != *"$owner_path"* ]]; then
            return 1
        fi
    done <<< "$owner_paths"

    return 0
}

test_evidence_bundle_exists_with_repo_safe_filename() {
    local basename
    basename="$(basename "$EVIDENCE_FILE")"

    if [ -f "$EVIDENCE_FILE" ]; then
        pass "evidence bundle file exists"
    else
        fail "evidence bundle file should exist at $EVIDENCE_FILE"
    fi

    assert_not_contains "$basename" "-" "evidence bundle filename should use underscores instead of dashes"
}

test_local_launch_readiness_links_latest_snapshot() {
    local readiness_content
    readiness_content="$(cat "$READINESS_DOC")"

    assert_contains "$readiness_content" "launch_readiness_evidence_20260420.md" \
        "LOCAL_LAUNCH_READINESS should link the latest evidence snapshot"
}

test_evidence_bundle_references_canonical_docs() {
    local evidence_content
    evidence_content="$(cat "$EVIDENCE_FILE")"

    assert_contains "$evidence_content" "docs/runbooks/staging-evidence.md" \
        "evidence bundle should link staging evidence"
    assert_contains "$evidence_content" "ROADMAP.md" \
        "evidence bundle should link roadmap status"
    assert_contains "$evidence_content" "PRIORITIES.md" \
        "evidence bundle should link priorities status"
    assert_contains "$evidence_content" "docs/LOCAL_LAUNCH_READINESS.md" \
        "evidence bundle should link local launch readiness"
}

test_evidence_bundle_covers_required_sections() {
    local evidence_content
    evidence_content="$(cat "$EVIDENCE_FILE")"

    assert_contains "$evidence_content" "## Summary Table" \
        "evidence bundle should include a summary table section"
    assert_contains "$evidence_content" "## Local Signoff" \
        "evidence bundle should include local signoff evidence"
    assert_contains "$evidence_content" "## Staging Infra" \
        "evidence bundle should include staging infrastructure evidence"
    assert_contains "$evidence_content" "## Browser Signoff" \
        "evidence bundle should include browser signoff evidence"
    assert_contains "$evidence_content" "## Cloudflare And DNS" \
        "evidence bundle should include Cloudflare/DNS status"
    assert_contains "$evidence_content" "## Billing Dry Run" \
        "evidence bundle should include billing dry-run status"
    assert_contains "$evidence_content" "## Deferred And Future" \
        "evidence bundle should include deferred/future items"
}

test_evidence_bundle_has_no_secret_like_values() {
    if grep -Eq "AKIA|sk_live|sk_test|whsec_|CLOUDFLARE.*=" "$EVIDENCE_FILE"; then
        fail "evidence bundle should not contain secret-looking values"
    else
        pass "evidence bundle avoids secret-looking values"
    fi
}

test_status_docs_reference_stage123_canonical_artifacts() {
    local roadmap_content priorities_content risk_content staging_evidence_content status_docs_content
    roadmap_content="$(cat "$ROADMAP_DOC")"
    priorities_content="$(cat "$PRIORITIES_DOC")"
    risk_content="$(cat "$GAPS_AND_RISKS_DOC")"
    staging_evidence_content="$(cat "$STAGING_EVIDENCE_DOC")"
    status_docs_content="$(printf '%s\n%s\n%s\n%s\n' "$roadmap_content" "$priorities_content" "$risk_content" "$staging_evidence_content")"

    assert_contains "$status_docs_content" "scripts/validate_ses_readiness.sh" \
        "status docs should reference scripts/validate_ses_readiness.sh"
    assert_contains "$status_docs_content" "scripts/launch/ses_deliverability_evidence.sh" \
        "status docs should reference scripts/launch/ses_deliverability_evidence.sh"
    assert_contains "$status_docs_content" "docs/runbooks/email-production.md" \
        "status docs should reference docs/runbooks/email-production.md"
    assert_contains "$status_docs_content" "docs/runbooks/account_data_policy.md" \
        "status docs should reference docs/runbooks/account_data_policy.md"
    assert_contains "$status_docs_content" "docs/runbooks/secret_rotation.md" \
        "status docs should reference docs/runbooks/secret_rotation.md"
    assert_contains "$status_docs_content" "load_env_file" \
        "status docs should preserve the canonical env-loader reference"
    assert_contains "$status_docs_content" "attach_payment_method" \
        "status docs should reference the attach_payment_method lifecycle step (historical blocker context)"
    assert_contains "$status_docs_content" "scripts/validate-stripe.sh" \
        "status docs should reference scripts/validate-stripe.sh as the credentialed Stripe lifecycle owner"
    assert_contains "$status_docs_content" "postgresql16" \
        "status docs should record the postgresql16 package as the host psql source (AMI + user_data + live staging host)"
    assert_contains "$status_docs_content" "docs/runbooks/evidence/database-recovery/" \
        "status docs should reference the committed RDS restore verification evidence path"
    assert_contains "$status_docs_content" "/Users/stuart/.matt/projects/fjcloud_dev-cd6902f9/apr23_am_1_ses_deliverability_refined.md-4c6ea1bd/artifacts/stage_04_ses_deliverability/fjcloud_ses_deliverability_evidence_20260423T063739Z_63867" \
        "status docs should reference the canonical Stage 4 wrapper run directory path"
    assert_contains "$status_docs_content" "docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md" \
        "status docs should reference the Stage 3 first_send_retrieval_status companion artifact path"
    if [[ "$status_docs_content" == *"bounce_blocker.txt"* ]] || [[ "$status_docs_content" == *"bounce_event.json"* ]]; then
        pass "status docs reference a Stage 4 bounce companion artifact path"
    else
        fail "status docs should reference either bounce_blocker.txt or bounce_event.json for Stage 4 bounce evidence status"
    fi
    if [[ "$status_docs_content" == *"complaint_blocker.txt"* ]] || [[ "$status_docs_content" == *"complaint_event.json"* ]]; then
        pass "status docs reference a Stage 5 complaint companion artifact path"
    else
        fail "status docs should reference either complaint_blocker.txt or complaint_event.json for Stage 5 complaint evidence status"
    fi
    assert_contains "$status_docs_content" "system@flapjack.foo" \
        "status docs should preserve system@flapjack.foo as the canonical sender identity"
    assert_not_contains "$status_docs_content" "noreply@flapjack.foo" \
        "status docs should not claim noreply@flapjack.foo as canonical sender identity"
    assert_not_contains "$status_docs_content" "Stripe staging credentials remain environment-blocked." \
        "status docs should not claim Stripe credentials are absent after Stage 3"
    assert_not_contains "$status_docs_content" 'SSM parameters for `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`: not set' \
        "status docs should not claim Stripe SSM parameters are unset after Stage 3"
    assert_not_contains "$staging_evidence_content" "the SES account remains sandboxed" \
        "staging evidence should not preserve stale current-state sandbox wording"
    assert_not_contains "$staging_evidence_content" "ProductionAccessEnabled=false" \
        "staging evidence should not preserve stale ProductionAccessEnabled=false blocker wording"
    assert_not_contains "$roadmap_content" "SES account is still sandboxed" \
        "roadmap should not preserve stale current-state sandbox wording"
    assert_not_contains "$roadmap_content" "ProductionAccessEnabled=false" \
        "roadmap should not preserve stale ProductionAccessEnabled=false blocker wording"
    assert_not_contains "$status_docs_content" "fix unsupported assignment syntax" \
        "status docs should not preserve stale SES env syntax blocker wording"
}

test_status_docs_preserve_stage123_residual_boundaries() {
    local roadmap_content priorities_content risk_content staging_evidence_content status_docs_content
    roadmap_content="$(cat "$ROADMAP_DOC")"
    priorities_content="$(cat "$PRIORITIES_DOC")"
    risk_content="$(cat "$GAPS_AND_RISKS_DOC")"
    staging_evidence_content="$(cat "$STAGING_EVIDENCE_DOC")"
    status_docs_content="$(printf '%s\n%s\n%s\n%s\n' "$roadmap_content" "$priorities_content" "$risk_content" "$staging_evidence_content")"

    assert_contains "$status_docs_content" "SPF" \
        "status docs should keep SPF as unproven deliverability evidence"
    assert_contains "$status_docs_content" "MAIL FROM" \
        "status docs should keep MAIL FROM as unproven deliverability evidence"
    assert_contains "$status_docs_content" "bounce/complaint" \
        "status docs should keep bounce/complaint handling as unproven evidence"
    assert_contains "$status_docs_content" "first-send" \
        "status docs should keep first-send evidence as unproven"
    assert_contains "$status_docs_content" "inbox-receipt" \
        "status docs should keep inbox-receipt evidence as unproven"
    assert_contains "$status_docs_content" "soft-delete" \
        "status docs should keep account deletion as soft-delete only"
    assert_contains "$status_docs_content" "hard erasure is not implemented" \
        "status docs should keep hard erasure as not implemented"
    assert_contains "$status_docs_content" "downstream cleanup is not implemented" \
        "status docs should keep downstream cleanup as not implemented"
    assert_contains "$status_docs_content" "retention duration is not yet automated" \
        "status docs should keep retention-duration automation as not implemented"
    assert_contains "$status_docs_content" "live rotations have not been executed" \
        "status docs should keep live secret rotations as not yet executed"
    assert_contains "$status_docs_content" "/browser-errors" \
        "status docs should document the repo-owned browser-runtime ingestion route"
    assert_contains "$status_docs_content" "broader panic/crash coverage remains future work if needed" \
        "status docs should narrow remaining error-reporting work to optional extended crash coverage"
    assert_contains "$status_docs_content" "30-day RDS PostgreSQL CloudWatch log-retention coverage" \
        "status docs should document 30-day RDS PostgreSQL CloudWatch log retention"
    assert_contains "$status_docs_content" "ops/terraform/data/main.tf" \
        "status docs should anchor RDS log retention to ops/terraform/data/main.tf"
    assert_contains "$status_docs_content" "docs/runbooks/infra-terraform-apply.md" \
        "status docs should reference terraform import/adoption runbook"
    assert_contains "$status_docs_content" "docs/runbooks/infra-alarm-triage.md" \
        "status docs should reference alarm triage runbook"
    assert_contains "$status_docs_content" "docs/runbooks/launch-backend.md" \
        "status docs should reference launch backend triage runbook"
    assert_contains "$status_docs_content" "/aws/rds/instance/fjcloud-<env>/postgresql" \
        "status docs should reference the RDS PostgreSQL CloudWatch log group"
    assert_contains "$status_docs_content" "journalctl" \
        "status docs should keep host journalctl as API evidence source"
    assert_contains "$status_docs_content" "unproven" \
        "status docs should explicitly frame residual SES boundaries as unproven"
    assert_not_contains "$status_docs_content" "boundary evidence was captured" \
        "status docs should not preserve proof-captured SES boundary phrasing"
    assert_not_contains "$status_docs_content" "Live-send boundary evidence captured" \
        "status docs should not preserve live-send proof-captured phrasing"
    assert_not_contains "$status_docs_content" "proof-complete" \
        "status docs should not preserve proof-complete SES boundary phrasing"
    assert_not_contains "$status_docs_content" "proof complete" \
        "status docs should not preserve proof complete SES boundary phrasing"
    assert_not_contains "$status_docs_content" "boundary proof is captured" \
        "status docs should not preserve boundary-proof-captured SES phrasing"

    assert_not_contains "$risk_content" "API application logs are centralized in CloudWatch" \
        "risk doc should not claim centralized API application logs in CloudWatch"
    assert_not_contains "$risk_content" "CloudWatch is the source of truth for API application logs" \
        "risk doc should not claim CloudWatch as API application log source of truth"
}

test_saved_ses_boundary_artifact_requires_real_suppression_snapshot() {
    local artifact_content
    artifact_content="$(cat "$SES_DELIVERABILITY_BOUNDARY_PROOF_ARTIFACT")"

    assert_not_contains "$artifact_content" "Unknown options: --max-results, 20" \
        "saved SES boundary proof artifact should not report the stale suppression parse error"
    assert_not_contains "$artifact_content" "Unknown options:" \
        "saved SES boundary proof artifact should not include any CLI parse-error output in suppression snapshot"
}

test_status_docs_track_stage1_boundary_proof_drift() {
    local staging_evidence_content reconciliation_content status_docs_content
    staging_evidence_content="$(cat "$STAGING_EVIDENCE_DOC")"
    reconciliation_content="$(cat "$SES_BOUNDARY_PROOF_RECONCILIATION")"
    status_docs_content="$(printf '%s\n%s\n' "$staging_evidence_content" "$reconciliation_content")"

    assert_contains "$reconciliation_content" "MailFromDomainStatus=SUCCESS" \
        "stage1 reconciliation should record MailFromDomainStatus=SUCCESS in live evidence"
    assert_contains "$reconciliation_content" '`drift`' \
        "stage1 reconciliation should keep MAIL FROM status drift explicitly marked"
    assert_contains "$reconciliation_content" "historical context and not as a competing source of truth" \
        "stage1 reconciliation should keep preserved transcript treatment as historical context only"
    assert_contains "$status_docs_content" "20260424_boundary_proof/reconciliation_summary.md" \
        "status docs should reference the Stage 1 reconciliation summary path directly"
    assert_not_contains "$staging_evidence_content" "MailFromDomainStatus=PENDING" \
        "staging evidence should not keep MailFromDomainStatus=PENDING after Stage 1 drift evidence"
}

test_beta_checklist_exists_with_repo_safe_filename() {
    local basename
    basename="$(basename "$BETA_CHECKLIST_DOC")"

    if [ -f "$BETA_CHECKLIST_DOC" ]; then
        pass "beta checklist file exists"
    else
        fail "beta checklist file should exist at $BETA_CHECKLIST_DOC"
    fi

    assert_not_contains "$basename" "-" "beta checklist filename should use underscores instead of dashes"
}

test_beta_checklist_top_of_file_authority_and_deferral_language() {
    local beta_preamble beta_preamble_lower
    if ! beta_preamble="$(head -n 80 "$BETA_CHECKLIST_DOC" 2>/dev/null)"; then
        pass "beta checklist authority/deferral checks deferred until beta checklist exists"
        return
    fi
    beta_preamble_lower="$(to_ascii_lower "$beta_preamble")"

    assert_contains "$beta_preamble_lower" "evergreen launch gate" \
        "beta checklist preamble should describe the checklist as an evergreen launch gate"
    assert_contains "$beta_preamble" "ROADMAP.md" \
        "beta checklist preamble should defer mutable blocker interpretation to ROADMAP.md"
    assert_contains "$beta_preamble" "PRIORITIES.md" \
        "beta checklist preamble should defer mutable blocker interpretation to PRIORITIES.md"
    assert_contains "$beta_preamble" "docs/runbooks/staging-evidence.md" \
        "beta checklist preamble should defer mutable blocker interpretation to docs/runbooks/staging-evidence.md"
    assert_contains "$beta_preamble" "docs/runbooks/paid_beta_rc_signoff.md" \
        "beta checklist preamble should cite paid_beta_rc_signoff for paid-beta RC semantics"
    assert_contains "$beta_preamble_lower" "readiness semantics" \
        "beta checklist preamble should scope paid_beta_rc_signoff usage to readiness semantics"
    assert_contains "$beta_preamble_lower" "delegated proof" \
        "beta checklist preamble should scope paid_beta_rc_signoff usage to delegated proof meaning"
    assert_contains "$beta_preamble_lower" "second roadmap" \
        "beta checklist preamble should explicitly reject becoming a second roadmap"
    assert_contains "$beta_preamble_lower" "wrapper" \
        "beta checklist preamble should explicitly warn against wrapper-verdict table duplication"
    assert_contains "$beta_preamble_lower" "verdict" \
        "beta checklist preamble should explicitly warn against wrapper-verdict table duplication"
}

test_beta_checklist_has_required_sections_in_stage1_order() {
    if [ ! -f "$BETA_CHECKLIST_DOC" ]; then
        pass "beta checklist section-order checks deferred until beta checklist exists"
        return
    fi

    local required_sections
    required_sections=(
        "## Launch Status Authority"
        "## Billing And Metering Proof Owners"
        "## Runtime And Infra Wrapper Owners"
        "## SES Deliverability Owners"
        "## Customer-Facing Surface Owners"
        "## External And Operator Obligations"
    )

    local previous_line current_line section
    previous_line=0
    for section in "${required_sections[@]}"; do
        current_line="$(beta_checklist_section_line_number "$section")"
        if [ -z "$current_line" ]; then
            fail "beta checklist should include required section heading '$section'"
            continue
        fi
        pass "beta checklist includes required section heading '$section'"

        if [ "$current_line" -le "$previous_line" ]; then
            fail "beta checklist section '$section' should appear after previous required section"
            continue
        fi
        pass "beta checklist section '$section' appears in required order"
        previous_line="$current_line"
    done
}

test_beta_checklist_items_require_ordered_owner_acceptance_status_and_stage1_owner_classes() {
    local beta_content
    if ! beta_content="$(load_beta_checklist_content)"; then
        pass "beta checklist item structure checks deferred until beta checklist exists"
        return
    fi

    local stage1_owner_map_content
    if ! stage1_owner_map_content="$(cat "$STAGE1_OWNER_MAP_CHECKLIST" 2>/dev/null)"; then
        fail "Stage 1 owner map checklist should exist at $STAGE1_OWNER_MAP_CHECKLIST"
        return
    fi

    local parser_output
    parser_output="$(
        awk '
        BEGIN {
            in_item = 0
            state = 0
            item_line = 0
            item_text = ""
        }
        function emit_error(message) {
            printf("ERROR\t%d\t%s\n", item_line, message)
            in_item = 0
            state = 0
            item_line = 0
            item_text = ""
        }
        function finalize_item() {
            if (!in_item) {
                return
            }
            if (state == 0) {
                emit_error("missing Owner: line")
                return
            }
            if (state == 1) {
                emit_error("missing Acceptance: line")
                return
            }
            if (state == 2) {
                emit_error("missing Status: line")
                return
            }
            in_item = 0
            state = 0
            item_line = 0
            item_text = ""
        }
        /^- \[[ x*d]\] / {
            finalize_item()
            in_item = 1
            state = 0
            item_line = NR
            item_text = $0
            next
        }
        {
            if (!in_item) {
                next
            }
            if ($0 ~ /^[[:space:]]*$/) {
                next
            }
            if ($0 ~ /^## /) {
                finalize_item()
                next
            }

            if (state == 0) {
                if ($0 ~ /^[[:space:]]*(-[[:space:]]*)?Owner:[[:space:]]*.+$/) {
                    owner_line = $0
                    sub(/^[[:space:]]*(-[[:space:]]*)?Owner:[[:space:]]*/, "", owner_line)
                    gsub(/`/, "", owner_line)
                    printf("OWNER\t%d\t%s\n", NR, owner_line)
                    state = 1
                    next
                }
                emit_error("expected Owner: as first metadata line")
                next
            }

            if (state == 1) {
                if ($0 ~ /^[[:space:]]*(-[[:space:]]*)?Acceptance:[[:space:]]*.+$/) {
                    state = 2
                    next
                }
                emit_error("expected Acceptance: immediately after Owner:")
                next
            }

            if (state == 2) {
                if ($0 ~ /^[[:space:]]*(-[[:space:]]*)?Status:[[:space:]]*.+$/) {
                    state = 3
                    in_item = 0
                    next
                }
                emit_error("expected Status: immediately after Acceptance:")
                next
            }
        }
        END {
            finalize_item()
        }' "$BETA_CHECKLIST_DOC"
    )"

    local kind line_number payload
    local owner_line_count structure_error_count owner_error_count
    owner_line_count=0
    structure_error_count=0
    owner_error_count=0

    while IFS=$'\t' read -r kind line_number payload; do
        if [ -z "$kind" ]; then
            continue
        fi
        if [ "$kind" = "ERROR" ]; then
            fail "beta checklist item at line $line_number violates Owner/Acceptance/Status contract: $payload"
            structure_error_count=$((structure_error_count + 1))
            continue
        fi
        if [ "$kind" = "OWNER" ]; then
            owner_line_count=$((owner_line_count + 1))
            if owner_resolves_to_stage1_class "$payload" "$stage1_owner_map_content"; then
                pass "beta checklist owner at line $line_number resolves to a Stage 1 owner class"
            else
                fail "beta checklist owner at line $line_number should resolve to a Stage 1 owner class or named external-owner label"
                owner_error_count=$((owner_error_count + 1))
            fi
        fi
    done <<< "$parser_output"

    if [ "$owner_line_count" -eq 0 ]; then
        fail "beta checklist should include at least one actionable item with an Owner:/Acceptance:/Status: block"
        return
    fi
    pass "beta checklist includes actionable items with Owner:/Acceptance:/Status: blocks"

    if [ "$structure_error_count" -eq 0 ]; then
        pass "beta checklist actionable items keep Owner:/Acceptance:/Status: in exact order"
    fi
    if [ "$owner_error_count" -eq 0 ]; then
        pass "beta checklist owners stay anchored to Stage 1 owner classes"
    fi
}

test_beta_checklist_citations_and_antipattern_guards() {
    local beta_content beta_content_lower
    if ! beta_content="$(load_beta_checklist_content)"; then
        pass "beta checklist citation/anti-pattern checks deferred until beta checklist exists"
        return
    fi
    beta_content_lower="$(to_ascii_lower "$beta_content")"

    assert_contains "$beta_content" "artifacts/stage_03_paid_beta_rc/rc_run_20260424T003133Z/coordinator_result.json" \
        "beta checklist should mirror the preserved Stage 3 coordinator_result artifact path"
    assert_contains "$beta_content" "ready=false" \
        "beta checklist should mirror preserved Stage 3 ready=false"
    assert_contains "$beta_content" "verdict=fail" \
        "beta checklist should mirror preserved Stage 3 verdict=fail"
    assert_contains "$beta_content" "scripts/launch/run_full_backend_validation.sh --paid-beta-rc" \
        "beta checklist should mirror the preserved paid-beta RC rerun owner command"

    assert_not_contains "$beta_content" "/tmp/" \
        "beta checklist should not reference /tmp artifact paths"
    if grep -Eq '\bTBD\b' "$BETA_CHECKLIST_DOC"; then
        fail "beta checklist should not contain TBD placeholders"
    else
        pass "beta checklist avoids TBD placeholders"
    fi
    if grep -Eq '<[A-Za-z0-9_./-]+>' "$BETA_CHECKLIST_DOC"; then
        fail "beta checklist should not contain angle-bracket placeholders"
    else
        pass "beta checklist avoids angle-bracket placeholders"
    fi
    assert_not_contains "$beta_content_lower" "verify manually" \
        "beta checklist should reject manual-verification wording"
    assert_not_contains "$beta_content" "launch readiness is currently blocked by the preserved Stage 3 paid-beta RC result" \
        "beta checklist should not copy blocker prose from PRIORITIES.md"
    assert_not_contains "$beta_content" "Current staging status" \
        "beta checklist should not copy blocker section prose from PRIORITIES.md"
    assert_not_contains "$beta_content" "summary.json is the run-level source of truth" \
        "beta checklist should not copy wrapper summary.json interpretation prose"
    assert_not_contains "$beta_content" 'Interpret `summary.json` fields as' \
        "beta checklist should not copy wrapper summary.json interpretation tables"
    assert_not_contains "$beta_content" "remaining launch work is to seed staging with synthetic customer traffic" \
        "beta checklist should reject stale synthetic-traffic-only launch-summary wording"
}

test_status_docs_align_to_preserved_stage3_rc_verdict() {
    local roadmap_content priorities_content staging_evidence_content status_docs_content
    roadmap_content="$(cat "$ROADMAP_DOC")"
    priorities_content="$(cat "$REPO_ROOT/PRIORITIES.md")"
    staging_evidence_content="$(cat "$STAGING_EVIDENCE_DOC")"
    status_docs_content="$(printf '%s\n%s\n%s\n' "$roadmap_content" "$priorities_content" "$staging_evidence_content")"

    assert_contains "$status_docs_content" "ready=false" \
        "status docs should reflect the preserved Stage 3 paid-beta RC ready=false result"
    assert_contains "$status_docs_content" "verdict=fail" \
        "status docs should reflect the preserved Stage 3 paid-beta RC verdict=fail result"
    assert_contains "$status_docs_content" "artifacts/stage_03_paid_beta_rc/rc_run_20260424T003133Z/coordinator_result.json" \
        "status docs should cite the preserved Stage 3 coordinator_result.json path"
    assert_contains "$status_docs_content" "scripts/launch/run_full_backend_validation.sh --paid-beta-rc" \
        "status docs should point to the paid-beta RC rerun owner command"
    assert_contains "$status_docs_content" "scripts/staging_billing_rehearsal.sh" \
        "status docs should point to the staging billing rehearsal owner command"
    assert_contains "$status_docs_content" "ops/terraform/tests_stage7_runtime_smoke.sh" \
        "status docs should point to the staging runtime smoke owner command"
    assert_contains "$status_docs_content" "scripts/e2e-preflight.sh" \
        "status docs should point to the browser preflight owner command"
    assert_not_contains "$status_docs_content" "final launch coordination is pending" \
        "status docs should not use stale launch-coordination-pending prose after Stage 3 preserved fail verdict"
    assert_not_contains "$status_docs_content" "remaining launch work is to seed staging with synthetic customer traffic" \
        "status docs should not collapse remaining launch work into synthetic-traffic-only wording"
}

echo "=== launch_readiness_evidence docs tests ==="
test_evidence_bundle_exists_with_repo_safe_filename
test_local_launch_readiness_links_latest_snapshot
test_evidence_bundle_references_canonical_docs
test_evidence_bundle_covers_required_sections
test_evidence_bundle_has_no_secret_like_values
test_status_docs_reference_stage123_canonical_artifacts
test_status_docs_preserve_stage123_residual_boundaries
test_saved_ses_boundary_artifact_requires_real_suppression_snapshot
test_status_docs_track_stage1_boundary_proof_drift
test_status_docs_align_to_preserved_stage3_rc_verdict
test_beta_checklist_exists_with_repo_safe_filename
test_beta_checklist_top_of_file_authority_and_deferral_language
test_beta_checklist_has_required_sections_in_stage1_order
test_beta_checklist_items_require_ordered_owner_acceptance_status_and_stage1_owner_classes
test_beta_checklist_citations_and_antipattern_guards
run_test_summary
