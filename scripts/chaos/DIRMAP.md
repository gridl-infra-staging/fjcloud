<!-- [scrai:start] -->
## chaos

| File | Summary |
| --- | --- |
| ha-failover-proof.sh | ha-failover-proof.sh — run an end-to-end local HA failover proof.

Workflow:
1) choose a cross-region active replica whose primary is in target region
2) kill the primary VM
3) wait for region-down + failover alerts
4) restart region processes
5) wait for recovery alert
6) verify tenant remains on promoted VM (no automatic switchback). |
| kill-region.sh | kill-region.sh — Kill a Flapjack region to test HA failover detection.

The health monitor (60s cycle, 3 failures = unhealthy) should detect the
killed region and log a "deployment unhealthy" alert. |
| metering_breaker_target_failure.sh | metering_breaker_target_failure.sh — prepared-local-stack chaos proof for metering breaker alerts.

Proof flow:
1) fail-closed preflight: local stack prepared + single loopback webhook channel
2) start isolated loopback fake metrics endpoint and webhook receiver
3) run metering-agent against fake metrics target
4) wait for first successful scrape
5) force failure by killing only the fake-metrics PID from this script's pid file
6) wait for exactly one breaker-open alert payload and assert SSOT metadata fields. |
| restart-region.sh | restart-region.sh — Restart a killed Flapjack region.

Requires the Flapjack binary to be available (FLAPJACK_DEV_DIR or in PATH).
After restart, the health monitor should detect recovery.

Usage:
  scripts/chaos/restart-region.sh eu-west-1. |
<!-- [scrai:end] -->
