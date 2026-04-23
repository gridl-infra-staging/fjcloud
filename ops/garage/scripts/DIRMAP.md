<!-- [scrai:start] -->
## scripts

| File | Summary |
| --- | --- |
| health-check.sh | health-check.sh — Probe Garage admin and S3 API endpoints

Returns exit 0 if both endpoints are healthy, exit 1 otherwise.
Suitable for cron, monitoring hooks, or manual verification.

Usage: health-check.sh [-q]
  -q  Quiet mode: only output on failure

Health criteria:
  Admin API (127.0.0.1:3903): HTTP 200 on /health
  S3 API    (127.0.0.1:3900): HTTP 200 or 403 (OQ-10: 403 = S3 up, auth required). |
| init-cluster.sh | init-cluster.sh — Initialize Garage cluster layout, create S3 credentials + bucket

Runs ONCE after first `systemctl start garage`. |
| install-garage.sh | install-garage.sh — Install Garage object storage as a systemd service

Downloads a pinned Garage binary with SHA256 verification, creates the
garage system user and data directories, installs the systemd unit +
sysctl config, and reloads systemd.

Usage: install-garage.sh

Prerequisites:
  - Root access (sudo)
  - curl installed
  - Internet access to garagehq.deuxfleurs.fr. |
<!-- [scrai:end] -->
