#!/usr/bin/env bash
# Shared staging billing input boundary helpers.

# TODO: Document clear_staging_billing_input_env.
# TODO: Document clear_staging_billing_input_env.
# TODO: Document clear_staging_billing_input_env.
# TODO: Document clear_staging_billing_input_env.
# TODO: Document clear_staging_billing_input_env.
# Unset every staging endpoint, credential, tenant, and AWS selector consumed by rehearsal lanes.
# Keep the canonical variable inventory here so callers cannot clear only a partial environment.
# TODO: Document clear_staging_billing_input_env.
# TODO: Document clear_staging_billing_input_env.
clear_staging_billing_input_env() {
    local var_name
    for var_name in \
        STAGING_API_URL \
        STAGING_STRIPE_WEBHOOK_URL \
        STRIPE_SECRET_KEY \
        STRIPE_WEBHOOK_SECRET \
        ADMIN_KEY \
        DATABASE_URL \
        INTEGRATION_DB_URL \
        MAILPIT_API_URL \
        FJCLOUD_TEST_TENANT_IDS \
        AWS_ACCESS_KEY_ID \
        AWS_SECRET_ACCESS_KEY \
        AWS_SESSION_TOKEN \
        AWS_PROFILE \
        AWS_DEFAULT_REGION \
        AWS_REGION
    do
        unset -v "$var_name"
    done
}
