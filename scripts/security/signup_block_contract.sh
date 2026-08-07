#!/usr/bin/env bash

# Single owner for the production registration-block contract.
#
# Two scripts depend on these values and MUST agree, or the control and its proof
# drift apart and the probe goes green for the wrong reason:
#   * scripts/security/apply_prod_signup_block.sh  -- renders the ALB rule
#   * scripts/security/probe_signup_closed.sh      -- asserts the rule is in force
#
# This file is sourced, never executed. It defines constants only -- so every
# assignment here is "unused" from shellcheck's single-file view.
# shellcheck disable=SC2034

# Marker carried in the ALB fixed-response body. The probe requires it, so a
# generic 503 from an ALB or target-group outage can never be mistaken for the
# deliberate block.
SIGNUP_BLOCK_MARKER="fjcloud-registration-closed"

# The route held shut. web/src/lib/api/client.ts:117 posts here, and
# infra/api/src/routes/auth.rs::register serves it, so this one path is the
# single choke point for both the console signup form and direct API clients.
SIGNUP_BLOCK_PATH="/auth/register"

# ALB listener-rule priority. The prod HTTPS listener carries no other rules
# (only its default forward), so 1 is free; keeping it low means the block is
# evaluated before anything added later can shadow it.
SIGNUP_BLOCK_PRIORITY=1

# Refusal status. 503 says "temporarily unavailable", which is the honest shape:
# registration is coming back once the engine data plane is TLS-only.
SIGNUP_BLOCK_STATUS=503

# The public prod API host the block defends. Named here so the applier's
# post-write verification probes the same host the rule was installed in front
# of, rather than taking a hostname from the caller's environment.
PROD_API_HOST="api.flapjack.foo"
