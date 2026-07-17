# Gap Spec Outcome

HEAD: 12c9227c6a55e3fe03a389bfc6da9050e21e0ae1
Bundle: docs/runbooks/evidence/ses-coverage-a1/20260712T220116Z_dunning_fix
Validator command rc: 1
Validator result: failed
Validator classification: dunning_subject_or_body_mismatch
Validator failing step: assert_dunning_transitions
Inbox command rc: 1
Inbox result: failed
Inbox classification: dunning_subject_or_body_mismatch
Inbox detail: dunning owner script exited 1
Secret hygiene rc: 0
Staging dev_sha: 35baf16307bbcc9056562b0eb5f0aa57039edc38
Dev main sha: 35baf16307bbcc9056562b0eb5f0aa57039edc38
Staging commits behind main: 0
Staging deployable drift: false
Dunning SES send-event diagnostic rc: 0
Dunning SES send-event matches for validator invoice IDs: 0
Dunning replay diagnosis: `scripts/validate_staging_dunning_delivery.sh` loaded `payload.transition_invoice_ids` from rehearsal artifacts, skipped the replay_dunning_webhooks branch, then searched inbound RFC822 objects for dunning transition subjects that this run did not generate.
