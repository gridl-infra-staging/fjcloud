# CloudWatch PanicsPerPeriod alarm readback

Probe UTC: `2026-07-09T11:51:01.837632+00:00`

Command: see `docs/runbooks/evidence/panics-alarm/20260709T114714Z/aws/cloudwatch_panics_probe_command.txt`.

No matching CloudWatch alarms with `MetricName == PanicsPerPeriod` were returned by the read-only probe.

Deployment-gap note: repo owners are authored and locally validated, but live infrastructure has not yet been applied or does not yet expose the authored alarm in this account/region. Evidence chain: `ops/terraform/monitoring/main.tf::aws_cloudwatch_metric_alarm.api_panics_high`, `infra/api/src/services/panics.rs::PanicsPublisher::publish_once`, and `docs/live-state/20260709T104747Z/`.
