<!-- [scrai:start] -->
## common

| File | Summary |
| --- | --- |
| builders.rs | Stub summary for builders.rs. |
| capacity_profiles.rs | Shared capacity profile fixtures for scheduler and placement tests.



These constants represent local measured resource envelopes for three

document tiers.

Memory and disk values were refreshed from

`scripts/reliability/profiles/` on 2026-03-24 after a real profiling run.

CPU weight and RPS fields still use provisional test-calibration defaults

because the current harness does not emit them directly.



Downstream stages consume these profiles to calibrate overload thresholds,

migration triggers, and placement scoring. |
| flapjack_proxy_test_support.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar25_am_3_customer_multitenant_multiregion_coverage/fjcloud_dev/infra/api/tests/common/flapjack_proxy_test_support.rs. |
| indexes_route_test_support.rs | Shared helpers for index route integration tests.



`MockFlapjackHttpClient` and `setup_ready_index` live in

`flapjack_proxy_test_support` — re-exported here so existing test

files can keep their imports unchanged. |
| integration_helpers.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/common/integration_helpers.rs. |
| live_stripe_helpers.rs | Stub summary for live_stripe_helpers.rs. |
| mocks.rs | Stub summary for mocks.rs. |
| poll.rs | Stub summary for poll.rs. |
| storage_metering_test_support.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/common/storage_metering_test_support.rs. |
| storage_s3_object_route_support.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/tests/common/storage_s3_object_route_support.rs. |
| storage_s3_signed_router_harness.rs | Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_3_load_testing_chaos/fjcloud_dev/infra/api/tests/common/storage_s3_signed_router_harness.rs. |
| stripe_webhook_test_support.rs | Stub summary for stripe_webhook_test_support.rs. |
<!-- [scrai:end] -->
