# Deployable-currency finding — `e1db1f6d8..HEAD`

**HEAD:** `2f04e0afccea7a0e165d699dfed79f90ebf78545`
**Range:** `e1db1f6d8..HEAD`
**Classifier owner:** `scripts/lib/deployable_currency.sh`

## (a) Filename-level verdict: `deployable_drift=true`

`classify_deployable_currency <repo> e1db1f6d8 HEAD` reports:

```
deployable_drift=true
doc_only_ahead=false
```

This is the **conservative, correct** filename-level answer. The ahead range
touches paths on the release-artifact allowlist (defined by the deploy jobs in
`.github/workflows/ci.yml`, not by commit subjects), including:

- `infra/api/src/services/email.rs`  ← the canonical deployable source path
- `infra/api/src/**/DIRMAP.md` and `infra/pricing-calculator/src/DIRMAP.md`

`doc_only_ahead=false` because the range ALSO carries non-doc paths outside the
allowlist (e.g. `scripts/**` shell changes from this very lane). The classifier
deliberately refuses to call a range "doc-only ahead" once any non-doc path is
present — filename-level only, no commit-subject heuristics.

## (b) Hunk-level proof: the compiled API binary is byte-identical

Although `email.rs` trips the filename flag, **every** added/removed line in the
`e1db1f6d8..HEAD` hunks for `infra/api/src/services/email.rs` is a Rust
doc-comment (`//!` module summary or `///` item doc). There is zero
executable-code delta:

```
-//! Stub summary for email.rs.
+//! Stub summary for infra/api/src/services/email.rs.
+    /// TODO: Document SesEmailService.send_invoice_ready_email.
+    /// TODO: Document SesEmailService.send_dunning_retry_scheduled_email.
+    /// TODO: Document SesEmailService.send_dunning_retries_exhausted_email.
+    /// TODO: Document SesEmailService.send_dunning_recovered_after_failure_email.
```

The `infra/billing` portion of the range is `infra/billing/DIRMAP.md` only — a
generated docs summary, no `.rs` change. Full hunk capture:
[`email_billing_ahead.diff`](./email_billing_ahead.diff).

Rust doc-comments do not affect codegen, so the compiled release artifact for
the API service is **byte-identical** across `e1db1f6d8..HEAD`. The green
staging billing rehearsal proof therefore stays **semantically current for HEAD**
despite the conservative filename-level `deployable_drift=true` flag: the flag
correctly says "a release-artifact path changed, re-review," and this hunk-level
read is exactly that review, concluding no runtime behavior changed.

## Live at-HEAD prod verdict

`deploy_status_prod.json` (live `scripts/deploy_status.sh --json --env prod`)
records the prod-deployed SHA vs dev main at capture time:
`{commits_behind_main: "134", deployable_drift: "true", doc_only_ahead: "false"}`
— an independent, genuinely-behind deployable verdict for the deployed prod SHA.
