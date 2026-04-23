#!/usr/bin/env bash
# Shared planned-step list for staging billing preflight/rehearsal JSON output.

billing_rehearsal_planned_steps_json() {
    python3 -c 'import json; print(json.dumps([
        "metering collection",
        "aggregation job",
        "invoice finalization",
        "Stripe test webhook delivery",
        "invoice paid reconciliation",
        "email evidence capture"
    ]))'
}
