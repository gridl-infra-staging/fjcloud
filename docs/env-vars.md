# Environment Variables

All environment variables used by the fjcloud API and web portal.

## API Core (Required)

| Variable              | Required | Default                      | Description                                                                                                                                                                                         |
| --------------------- | -------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DATABASE_URL`        | Yes      | —                            | PostgreSQL connection string (e.g., `postgres://user:pass@host:5432/fjcloud`)                                                                                                                       |
| `JWT_SECRET`          | Yes      | —                            | Secret key for signing/verifying JWT tokens                                                                                                                                                         |
| `ADMIN_KEY`           | Yes      | —                            | Admin API authentication key (compared via constant-time `subtle` crate)                                                                                                                            |
| `LISTEN_ADDR`         | No       | `0.0.0.0:3001`               | Address and port the API server binds to                                                                                                                                                            |
| `RUST_LOG`            | No       | `info,api=debug`             | Log level filter (standard `tracing_subscriber` format)                                                                                                                                             |
| `ENVIRONMENT`         | No       | `unknown`                    | Environment name included in alert messages (e.g., `staging`, `prod`). Set to `local`, `dev`, or `development` together with `NODE_SECRET_BACKEND=memory` to enable local zero-dependency fallbacks. When set to `prod` or `production`, startup requires at least one non-blank alert webhook (`SLACK_WEBHOOK_URL` or `DISCORD_WEBHOOK_URL`) |
| `NODE_SECRET_BACKEND` | No       | `auto`                       | Node secret backend: `auto` (SSM when AWS provisioner is configured), `ssm`, `memory` (local dev), or `disabled`                                                                                    |
| `APP_BASE_URL`        | No       | `https://cloud.flapjack.foo` | Browser application base URL used when rendering transactional auth links. Startup trims a trailing slash so email templates do not emit double slashes                                             |

**Cloud API notes:** The `customers` table includes a `service_type` column (default: `flapjack`) added in Stage 1. This column identifies the managed search engine type per tenant and is included in service discovery responses.

## Stripe

| Variable                    | Required | Default                                 | Description                                                                                                                                                                       |
| --------------------------- | -------- | --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `STRIPE_SECRET_KEY`         | No       | —                                       | Stripe API secret key. If not set, Stripe operations log a warning and fail                                                                                                       |
| `STRIPE_PUBLISHABLE_KEY`    | No       | —                                       | Stripe publishable key for frontend Elements integration                                                                                                                          |
| `STRIPE_WEBHOOK_SECRET`     | No       | —                                       | Stripe webhook signing secret for signature verification                                                                                                                          |
| `STRIPE_WEBHOOK_FORWARD_TO` | No       | `http://localhost:3001/webhooks/stripe` | Operator-facing override for `stripe listen --forward-to` hints in backend launch scripts; set to `http://localhost:3099/webhooks/stripe` when validating the integration stack   |
| `STRIPE_SUCCESS_URL`        | No       | `http://localhost:5173/dashboard`       | Redirect URL after successful Stripe checkout                                                                                                                                     |
| `STRIPE_CANCEL_URL`         | No       | `http://localhost:5173/dashboard`       | Redirect URL after cancelled Stripe checkout                                                                                                                                      |
| `STRIPE_LOCAL_MODE`         | No       | —                                       | Set to `1` to enable `LocalStripeService` — a stateful in-process Stripe mock with webhook dispatch. Used when `STRIPE_SECRET_KEY` is absent. All billing operations work offline |
| `STRIPE_WEBHOOK_URL`        | No       | `http://localhost:3001/webhooks/stripe` | URL where `LocalStripeService` dispatches webhook events. Only used when `STRIPE_LOCAL_MODE=1`                                                                                    |

Compatibility note: `STRIPE_SECRET_KEY` is the canonical operator-facing variable. Shared launch/validation helpers in `scripts/lib/stripe_checks.sh` and `scripts/validate-stripe.sh` still support `STRIPE_TEST_SECRET_KEY` only as a compatibility fallback when `STRIPE_SECRET_KEY` is unset. Staging runtime preflights such as `scripts/staging_billing_dry_run.sh` require canonical `STRIPE_SECRET_KEY` because they validate the API's actual runtime contract.

## Internal Auth

| Variable              | Required | Default | Description                                                                                                     |
| --------------------- | -------- | ------- | --------------------------------------------------------------------------------------------------------------- |
| `INTERNAL_AUTH_TOKEN` | No       | —       | Bearer token for `/internal/*` endpoints (service-to-service auth). If unset, all internal endpoints return 401 |

## Email (SES)

Transactional emails (verification, password reset, invoice-ready, quota warning) render once into a shared `{ subject, html_body, text_body }` contract before SES, Mailpit, or test mocks deliver them.

| Variable                | Required | Default | Description                                                                                                                                                                                                                                                                                      |
| ----------------------- | -------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SES_FROM_ADDRESS`      | Prod     | —       | Sender address for transactional emails (e.g., `system@flapjack.foo`). When `ENVIRONMENT` is `local`/`dev`/`development`, `NODE_SECRET_BACKEND=memory`, and the full SES env family is absent, startup uses `NoopEmailService`                                                               |
| `EMAIL_FROM_NAME`       | No       | `Flapjack Cloud` | Sender display name for transactional emails. Shared by SES and Mailpit sender identity wiring; blank values fall back to the default                                                                                                                  |
| `SES_REGION`            | Prod     | —       | AWS region for SES API calls (e.g., `us-east-1`). When `ENVIRONMENT` is `local`/`dev`/`development`, `NODE_SECRET_BACKEND=memory`, and the full SES env family is absent, startup uses `NoopEmailService`                                                                                     |
| `SES_CONFIGURATION_SET` | Prod     | —       | SES configuration set name applied to outbound SES sends so bounce/complaint events publish through the configured SES event destination. Startup fails fast when SES mode is active and this variable is missing or blank; suppression-aware outbound checks still flow through the same central SES startup path |

## SES Inbound Test Probe

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `INBOUND_ROUNDTRIP_S3_URI` | No | `s3://flapjack-cloud-releases/e2e-emails/` | S3 sink URI polled by `scripts/validate_inbound_email_roundtrip.sh` when searching for inbound test inbox objects |
| `INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS` | No | `30` | Max S3 poll attempts before the inbound roundtrip probe times out |
| `INBOUND_ROUNDTRIP_POLL_SLEEP_SEC` | No | `2` | Sleep interval in seconds between S3 poll attempts |
| `INBOUND_ROUNDTRIP_NONCE` | No | auto-generated | Optional explicit nonce override used to build deterministic probe subject/body and recipient local part |
| `INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN` | No | `test.flapjack.foo` | Recipient domain for probe delivery target |
| `INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART` | No | `roundtrip-<nonce>` | Recipient local part used to build `<localpart>@<domain>` probe address |

## Email (Mailpit — Local Dev)

| Variable             | Required | Default               | Description                                                                                                                                                                                                         |
| -------------------- | -------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MAILPIT_API_URL`    | No       | —                     | Mailpit HTTP API base URL (e.g., `http://localhost:8025`). When set and SES env is absent, startup uses `MailpitEmailService` instead of `NoopEmailService`. Emails are caught by Mailpit and visible in its web UI |
| `EMAIL_FROM_ADDRESS` | No       | `system@flapjack.foo` | Sender email address for `MailpitEmailService`                                                                                                                                                                      |
| `EMAIL_FROM_NAME`    | No       | `Flapjack Cloud`      | Shared transactional sender display name used by Mailpit and SES; `MailpitEmailService` consumes the same startup/config defaulting path as SES                                                                                                       |

## AWS (EC2 / Route53 / SSM)

| Variable                    | Required | Default        | Description                                                                                                                                                                                                                                                                  |
| --------------------------- | -------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `AWS_AMI_ID`                | Yes\*    | —              | AMI ID for search engine VM instances                                                                                                                                                                                                                                        |
| `AWS_SUBNET_ID`             | Yes\*    | —              | VPC subnet for VM placement                                                                                                                                                                                                                                                  |
| `AWS_SECURITY_GROUP_IDS`    | Yes\*    | —              | Comma-separated security group IDs                                                                                                                                                                                                                                           |
| `AWS_KEY_PAIR_NAME`         | Yes\*    | —              | EC2 key pair name for SSH access                                                                                                                                                                                                                                             |
| `AWS_INSTANCE_PROFILE_NAME` | No       | —              | IAM instance profile for VMs (enables IMDS tag access)                                                                                                                                                                                                                       |
| `DNS_HOSTED_ZONE_ID`        | No       | —              | Route53 hosted zone ID. If not set, DNS operations fail                                                                                                                                                                                                                      |
| `DNS_DOMAIN`                | No       | `flapjack.foo` | Base domain for VM hostnames (e.g., `vm-<id>.flapjack.foo`)                                                                                                                                                                                                                  |
| `RDS_RESTORE_DRILL_EXECUTE` | No       | unset          | Operator-only gate for `ops/scripts/rds_restore_drill.sh`. Unset keeps restore drill in dry-run mode; set to `1` to allow a live AWS restore API call. The drill intentionally rejects password-bearing CLI flags so secrets are not exposed through local process arguments |

\*Required when provisioning VMs. The API starts without them but provisioning calls will fail.

## Cloudflare (Public Staging DNS)

| Variable                                               | Required           | Default | Description                                                                                                                                                                       |
| ------------------------------------------------------ | ------------------ | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLOUDFLARE_API_TOKEN`                                 | Staging/Prod infra | —       | Cloudflare API token with Zone:Read and DNS:Edit permissions for the public zone. Used by Terraform and staging DNS validation; keep it in the operator secret file, not the repo |
| `CLOUDFLARE_ZONE_ID`                                   | Staging/Prod infra | —       | Cloudflare zone ID for the public DNS zone passed to Terraform as `cloudflare_zone_id`                                                                                            |
| `CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO` | Staging infra      | —       | Domain-specific alias for the `flapjack.foo` Cloudflare token. The staging smoke harness and bootstrap validator accept this when `CLOUDFLARE_API_TOKEN` is absent                |
| `CLOUDFLARE_ZONE_ID_FLAPJACK_FOO`                      | Staging infra      | —       | Domain-specific alias for the `flapjack.foo` Cloudflare zone ID. The staging smoke harness and bootstrap validator accept this when `CLOUDFLARE_ZONE_ID` is absent                |
| `CLOUDFLARE_GLOBAL_API_KEY`                            | Operator-only      | —       | Legacy Cloudflare global API key used by Pages/Wrangler and `ops/runbooks/site_takedown_20260503/restore.sh` because the zone-scoped DNS token is insufficient for those calls   |
| `CLOUDFLARE_X_Auth_Email`                              | Operator-only      | —       | Email paired with `CLOUDFLARE_GLOBAL_API_KEY` for legacy Cloudflare X-Auth requests in Pages/Wrangler and the site-restore runbook                                             |

## Live E2E Guardrails

| Variable                        | Required | Default | Description                                                                                                                                              |
| ------------------------------- | -------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FJCLOUD_ALLOW_LIVE_E2E_DELETE` | No       | unset   | Required only for destructive TTL janitor runs. `ops/scripts/live_e2e_ttl_janitor.sh` remains dry-run unless this is exactly `1` and `--execute` is set. |

## Alerting

| Variable              | Required | Default | Description                                   |
| --------------------- | -------- | ------- | --------------------------------------------- |
| `SLACK_WEBHOOK_URL`   | Prod\*   | —       | Slack incoming webhook URL for alert delivery |
| `DISCORD_WEBHOOK_URL` | Prod\*   | —       | Discord webhook URL for alert delivery        |

\*When `ENVIRONMENT` is `prod` or `production`, startup fails closed unless at least one webhook is non-blank (`SLACK_WEBHOOK_URL` or `DISCORD_WEBHOOK_URL`).

Outside `prod`/`production`, if both webhook variables are absent or blank, alerts fall back to `LogAlertService` (logged via `tracing`, persisted to DB with `delivery_status=logged`).

## CORS & Rate Limiting

| Variable                | Required | Default                                               | Description                                                                                                                                                                             |
| ----------------------- | -------- | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CORS_ALLOWED_ORIGINS`  | No       | `http://localhost:5173`, `https://cloud.flapjack.foo` | Comma-separated allowed CORS origins. Runtime fallback includes the local web origin and canonical Flapjack Cloud browser origin                                                        |
| `AUTH_RATE_LIMIT_RPM`   | No       | `10`                                                  | Max requests per minute per IP on `/auth/*` endpoints                                                                                                                                   |
| `TENANT_RATE_LIMIT_RPM` | No       | `100`                                                 | Max requests per minute per tenant on customer API endpoints                                                                                                                            |
| `ADMIN_RATE_LIMIT_RPM`  | No       | `30`                                                  | Max requests per minute per IP on `/admin/*` endpoints. For browser-unmocked local signoff runs, set a higher local-only value such as `300` in `.env.local` to avoid harness-only 429s |
| `DEFAULT_MAX_QUERY_RPS` | No       | `10`                                                  | Max search queries per second per tenant-index (sliding window, returns 429). Launch default is conservative; plan to raise within a few months of public launch                        |
| `DEFAULT_MAX_WRITE_RPS` | No       | `10`                                                  | Max write operations per second per tenant-index (sliding window, returns 429). Launch default is conservative; plan to raise within a few months of public launch                      |

## Cold Storage (Stage 8)

| Variable                  | Required | Default        | Description                                                                                                                                                                       |
| ------------------------- | -------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `COLD_STORAGE_BUCKET`     | No       | `fjcloud-cold` | S3/R2 bucket name for cold index snapshots                                                                                                                                        |
| `COLD_STORAGE_PREFIX`     | No       | (empty)        | Key prefix within the bucket (e.g., `prod/` to namespace environments)                                                                                                            |
| `COLD_STORAGE_REGION`     | No       | `us-east-1`    | AWS region for the cold storage bucket                                                                                                                                            |
| `COLD_STORAGE_ACCESS_KEY` | No       | —              | Explicit access key for the cold-storage S3-compatible endpoint; when paired with `COLD_STORAGE_SECRET_KEY`, overrides the AWS SDK default credential chain for cold storage only |
| `COLD_STORAGE_SECRET_KEY` | No       | —              | Explicit secret key for the cold-storage S3-compatible endpoint; keep out of committed env files except deterministic local-dev credentials                                       |

**Local dev note:** When `ENVIRONMENT` is `local`/`dev`/`development`, `NODE_SECRET_BACKEND=memory`, and the entire `COLD_STORAGE_*` family (`COLD_STORAGE_BUCKET`, `COLD_STORAGE_PREFIX`, `COLD_STORAGE_REGION`, `COLD_STORAGE_ENDPOINT`, `COLD_STORAGE_REGIONS`, `COLD_STORAGE_ACCESS_KEY`, `COLD_STORAGE_SECRET_KEY`) is absent, startup uses `InMemoryObjectStore` instead of S3. The S3 bucket/region defaults shown above apply only when the S3 path is active.

## Cold Tier Manager (Stage 8)

| Variable                             | Required | Default | Description                                                                 |
| ------------------------------------ | -------- | ------- | --------------------------------------------------------------------------- |
| `COLD_TIER_IDLE_THRESHOLD_DAYS`      | No       | `30`    | Days of zero search activity before an index is eligible for cold tiering   |
| `COLD_TIER_CYCLE_INTERVAL_SECS`      | No       | `3600`  | Seconds between cold tier detection cycles                                  |
| `COLD_TIER_MAX_CONCURRENT_SNAPSHOTS` | No       | `2`     | Max snapshot exports running in parallel per cycle                          |
| `COLD_TIER_SNAPSHOT_TIMEOUT_SECS`    | No       | `600`   | Timeout (seconds) for a single snapshot export+upload                       |
| `COLD_TIER_MAX_SNAPSHOT_RETRIES`     | No       | `3`     | Max retries for a failed snapshot before firing a critical alert            |
| `COLD_TIER_MAX_CANDIDATES_PER_CYCLE` | No       | `5`     | Max indexes evaluated for cold tiering per cycle (prevents thundering herd) |

## Restore (Stage 8)

| Variable                 | Required | Default | Description                                                 |
| ------------------------ | -------- | ------- | ----------------------------------------------------------- |
| `RESTORE_MAX_CONCURRENT` | No       | `3`     | Max concurrent restore jobs (429 returned when at capacity) |
| `RESTORE_TIMEOUT_SECS`   | No       | `300`   | Timeout (seconds) for a single restore download+import      |

## Hetzner Cloud (Stage 9)

| Variable               | Required | Default        | Description                                                                    |
| ---------------------- | -------- | -------------- | ------------------------------------------------------------------------------ |
| `HETZNER_API_TOKEN`    | No       | —              | Hetzner Cloud API bearer token. If not set, Hetzner provisioner is unavailable |
| `HETZNER_SERVER_TYPE`  | No       | `cpx32`        | Hetzner server type (4 vCPU AMD EPYC, 8 GB RAM, 160 GB NVMe)                   |
| `HETZNER_IMAGE`        | No       | `ubuntu-22.04` | Hetzner OS image (flapjack installed via cloud-init)                           |
| `HETZNER_SSH_KEY_NAME` | No       | —              | Name of SSH key pre-uploaded to Hetzner console                                |
| `HETZNER_FIREWALL_ID`  | No       | —              | Hetzner firewall ID (allow TCP 7700, 22, 9090)                                 |
| `HETZNER_NETWORK_ID`   | No       | —              | Hetzner private network ID (if set, prefer private IP for flapjack URL)        |
| `HETZNER_LOCATION`     | No       | `fsn1`         | Default Hetzner datacenter location (fsn1, nbg1, hel1, ash, hil, sin)          |

## GCP Compute (Stretch)

| Variable                      | Required | Default                                                         | Description                                                                                      |
| ----------------------------- | -------- | --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `GCP_API_TOKEN`               | No       | —                                                               | GCP OAuth2 bearer token for Compute Engine API calls. If not set, GCP provisioner is unavailable |
| `GCP_PROJECT_ID`              | No       | —                                                               | GCP project ID used for instance lifecycle API calls                                             |
| `GCP_ZONE`                    | No       | `us-central1-a`                                                 | Default Compute Engine zone (used when provider location is not passed at create time)           |
| `GCP_MACHINE_TYPE`            | No       | `e2-standard-4`                                                 | Compute Engine machine type used for new instances                                               |
| `GCP_IMAGE`                   | No       | `projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts` | Boot image for new instances                                                                     |
| `GCP_NETWORK`                 | No       | `global/networks/default`                                       | VPC network self-link/path used in instance network interfaces                                   |
| `GCP_SUBNETWORK`              | No       | —                                                               | Optional subnetwork self-link/path for instance placement                                        |
| `GCP_CREATE_POLL_ATTEMPTS`    | No       | `10`                                                            | Max poll attempts after instance create while waiting for a public IP                            |
| `GCP_CREATE_POLL_INTERVAL_MS` | No       | `2000`                                                          | Poll interval in milliseconds between create-time status/IP checks                               |

## OCI Compute (Stretch)

| Variable                      | Required | Default                   | Description                                                                                                    |
| ----------------------------- | -------- | ------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `OCI_TENANCY_OCID`            | No       | —                         | OCI tenancy OCID used in request-signing keyId (`<tenancy>/<user>/<fingerprint>`)                              |
| `OCI_USER_OCID`               | No       | —                         | OCI user OCID for API signing identity                                                                         |
| `OCI_KEY_FINGERPRINT`         | No       | —                         | Fingerprint for the API key pair associated with `OCI_USER_OCID`                                               |
| `OCI_PRIVATE_KEY_PATH`        | No       | —                         | Filesystem path to PEM private key used to sign OCI REST API requests                                          |
| `OCI_COMPARTMENT_ID`          | No       | —                         | OCI compartment OCID where instances are launched                                                              |
| `OCI_AVAILABILITY_DOMAIN`     | No       | —                         | Default OCI availability domain for launch requests (used when provider location is not passed at create time) |
| `OCI_SUBNET_ID`               | No       | —                         | OCI subnet OCID used for VNIC creation                                                                         |
| `OCI_IMAGE_ID`                | No       | —                         | OCI image OCID used to boot new instances                                                                      |
| `OCI_REGION`                  | No       | `us-ashburn-1`            | OCI region used to build default API base URL                                                                  |
| `OCI_API_BASE_URL`            | No       | Derived from `OCI_REGION` | Optional API endpoint override (e.g., private endpoint or test endpoint)                                       |
| `OCI_SHAPE`                   | No       | `VM.Standard.E4.Flex`     | OCI instance shape used for new instances                                                                      |
| `OCI_SHAPE_OCPUS`             | No       | `4.0`                     | OCPU value used in launch `shapeConfig`                                                                        |
| `OCI_SHAPE_MEMORY_GBS`        | No       | `16.0`                    | Memory (GiB) used in launch `shapeConfig`                                                                      |
| `OCI_CREATE_POLL_ATTEMPTS`    | No       | `10`                      | Max poll attempts after launch while waiting for VNIC/public IP                                                |
| `OCI_CREATE_POLL_INTERVAL_MS` | No       | `2000`                    | Poll interval in milliseconds between launch-time status/IP checks                                             |

## SSH Bare-Metal (Stretch)

| Variable       | Required | Default | Description                                                                                                                                                                   |
| -------------- | -------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SSH_KEY_PATH` | Yes\*    | —       | Filesystem path to SSH private key used for bare-metal server access                                                                                                          |
| `SSH_USER`     | No       | `root`  | SSH username for connecting to bare-metal servers                                                                                                                             |
| `SSH_PORT`     | No       | `22`    | SSH port for connecting to bare-metal servers                                                                                                                                 |
| `SSH_SERVERS`  | Yes\*    | —       | JSON array of bare-metal servers: `[{"id":"bm-01","host":"bm.example.com","public_ip":"1.2.3.4","private_ip":"10.0.0.1","region":"eu-central-bm"}]`. `private_ip` is optional |

\*Required when using bare-metal provisioner. The API starts without them but bare-metal provisioning will be unavailable.

## Multi-Cloud Region Config (Stage 9)

| Variable                | Required | Default          | Description                                                                                                                                                                                                                                                                                                     |
| ----------------------- | -------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REGION_CONFIG`         | No       | Built-in default | JSON override for region-to-provider mapping. Default includes 6 regions across AWS and Hetzner; add GCP/OCI mappings here when those providers are configured                                                                                                                                                  |
| `COLD_STORAGE_ENDPOINT` | No       | —                | S3-compatible endpoint URL (e.g., `https://fsn1.your-objectstorage.com`). When set, enables Hetzner Object Storage; when unset, uses standard AWS S3                                                                                                                                                            |
| `COLD_STORAGE_REGIONS`  | No       | —                | JSON map of per-region cold-storage overrides. Each entry configures `{bucket, region, prefix?, endpoint?, access_key?, secret_key?}` for that compute region (example: `{\"eu-central-1\":{\"bucket\":\"fjcloud-cold-eu\",\"region\":\"eu-central-1\",\"endpoint\":\"https://fsn1.your-objectstorage.com\"}}`) |

## Region Failover Monitor

| Variable                              | Required | Default | Description                                                                                                                                  |
| ------------------------------------- | -------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `REGION_FAILOVER_CYCLE_INTERVAL_SECS` | No       | `60`    | Seconds between region health probe cycles. Must be > 0 (invalid/zero values fall back to default). Set lower (e.g., `10`) for local HA demo |
| `REGION_FAILOVER_UNHEALTHY_THRESHOLD` | No       | `3`     | Consecutive unhealthy cycles before declaring a region down and initiating automatic failover. Must be > 0                                   |
| `REGION_FAILOVER_RECOVERY_THRESHOLD`  | No       | `2`     | Consecutive healthy cycles before declaring a region recovered. Must be > 0. Recovery is informational — no automatic switchback             |

## Replication Orchestrator (Stretch)

| Variable                             | Required | Default  | Description                                                                                                                                                                                                          |
| ------------------------------------ | -------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REPLICATION_CYCLE_INTERVAL_SECS`    | No       | `30`     | Seconds between replication orchestration cycles. Must be > 0 (invalid values fall back to default). Set very high (e.g., `999999`) in local dev to effectively disable — local Flapjack lacks `/internal/replicate` |
| `REPLICATION_NEAR_ZERO_LAG_OPS`      | No       | `100`    | Lag (ops) threshold to promote syncing/replicating replicas to active. Must be >= 0                                                                                                                                  |
| `REPLICATION_MAX_ACCEPTABLE_LAG_OPS` | No       | `100000` | Lag (ops) threshold above which active replicas are marked failed. Must be > 0                                                                                                                                       |
| `REPLICATION_SYNCING_TIMEOUT_SECS`   | No       | `3600`   | Maximum time a replica may remain syncing/replicating before failure. Must be > 0                                                                                                                                    |

## S3 API (Stage 5)

| Variable            | Required | Default        | Description                                                                                                 |
| ------------------- | -------- | -------------- | ----------------------------------------------------------------------------------------------------------- |
| `S3_LISTEN_ADDR`    | No       | `0.0.0.0:3002` | Address and port the S3-compatible API binds to (separate listener from REST API)                           |
| `S3_RATE_LIMIT_RPS` | No       | `100`          | Max requests per second per customer on the S3 API (sliding window, returns 503 SlowDown XML when exceeded) |

## Storage Service (Stage 3)

| Variable                 | Required | Default                 | Description                                                                                                                                                                                                                                                            |
| ------------------------ | -------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `STORAGE_ENCRYPTION_KEY` | Prod     | —                       | 64-char hex-encoded AES-256 master key for encrypting S3 access key secrets at rest. Generate with `openssl rand -hex 32`. When `ENVIRONMENT` is `local`/`dev`/`development`, `NODE_SECRET_BACKEND=memory`, and the key is unset, startup uses a deterministic dev key |
| `GARAGE_ADMIN_ENDPOINT`  | No       | `http://127.0.0.1:3903` | Garage admin API endpoint used by `ReqwestGarageAdminClient` for bucket/key lifecycle                                                                                                                                                                                  |
| `GARAGE_ADMIN_TOKEN`     | No       | —                       | Bearer token for Garage admin API authentication                                                                                                                                                                                                                       |

## Garage Object Storage (Infrastructure)

Generated by `ops/garage/scripts/init-cluster.sh` into `/etc/garage/env`.
These are infrastructure-level variables for Garage admin and S3 access.
`GARAGE_RPC_SECRET`, `GARAGE_META_DIR`, `GARAGE_DATA_DIR`,
`GARAGE_ADMIN_ENDPOINT`, `GARAGE_S3_ENDPOINT`, and `GARAGE_S3_REGION` are
copied or derived from `/etc/garage/garage.toml` so downstream tooling can read
the full Stage 1 Garage contract from a single env file.
Application-level cold storage uses `COLD_STORAGE_*` variables above.

| Variable                | Required | Default                 | Description                                                       |
| ----------------------- | -------- | ----------------------- | ----------------------------------------------------------------- |
| `GARAGE_META_DIR`       | No       | `/var/lib/garage/meta`  | Garage metadata directory from `garage.toml`                      |
| `GARAGE_DATA_DIR`       | No       | `/var/lib/garage/data`  | Garage data directory from `garage.toml`                          |
| `GARAGE_RPC_SECRET`     | No       | —                       | Garage inter-node RPC secret from `garage.toml`                   |
| `GARAGE_ADMIN_ENDPOINT` | No       | `http://127.0.0.1:3903` | Admin API endpoint (localhost only)                               |
| `GARAGE_ADMIN_TOKEN`    | No       | —                       | Admin API token from `garage.toml` copied into `/etc/garage/env`  |
| `GARAGE_S3_ENDPOINT`    | No       | `http://127.0.0.1:3900` | Garage S3 API endpoint (set as `COLD_STORAGE_ENDPOINT` to bridge) |
| `GARAGE_S3_REGION`      | No       | `garage`                | Garage S3 region name                                             |
| `GARAGE_S3_BUCKET`      | No       | `cold-storage`          | Garage bucket name for cold tier data                             |
| `GARAGE_S3_ACCESS_KEY`  | No       | —                       | S3 access key generated by `init-cluster.sh`                      |
| `GARAGE_S3_SECRET_KEY`  | No       | —                       | S3 secret key generated by `init-cluster.sh`                      |

### Cold Tier Bridge

To point the cold tier pipeline at the local Garage instance, map Garage infra
vars to the app-level `COLD_STORAGE_*` credential vars at deployment
time. See `docs/runbooks/garage-ops.md` section 8 for setup and verification.

| Garage Infra Var       | App-Level Var             | Purpose                                                       |
| ---------------------- | ------------------------- | ------------------------------------------------------------- |
| `GARAGE_S3_ENDPOINT`   | `COLD_STORAGE_ENDPOINT`   | Triggers `force_path_style(true)` in `S3ObjectStore`          |
| `GARAGE_S3_REGION`     | `COLD_STORAGE_REGION`     | Passed to `aws_sdk_s3::config::Region::new()` (opaque string) |
| `GARAGE_S3_BUCKET`     | `COLD_STORAGE_BUCKET`     | Overrides default `fjcloud-cold`                              |
| `GARAGE_S3_ACCESS_KEY` | `COLD_STORAGE_ACCESS_KEY` | Cold-storage-only S3 access key                               |
| `GARAGE_S3_SECRET_KEY` | `COLD_STORAGE_SECRET_KEY` | Cold-storage-only S3 secret key                               |

**Note:** Prefer the cold-storage-specific credential vars above. Setting
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` globally can accidentally override
EC2/Route53 provisioner credentials in the same process environment.

## Local Development

Variables used during local development. Some are consumed by local wrapper scripts, some by `scripts/seed_local.sh`, and others are read by the API server at runtime because they are primarily useful in local-dev contexts. All three wrapper scripts share the env-parsing helpers in `scripts/lib/env.sh`: `local-dev-up.sh` and `api-dev.sh` use strict `load_env_file` when they need to export a full `.env.local`, while `integration-up.sh` reuses the same line parser to read specific assignments without sourcing executable shell.

Run `scripts/bootstrap-env-local.sh` to generate `.env.local` from `.env.local.example` with safe random values for `JWT_SECRET` and `ADMIN_KEY`. The bootstrap is also auto-invoked by `scripts/local-dev-up.sh` when `.env.local` is missing. It never overwrites an existing file.

| Variable                      | Required | Default                                                 | Consumed by                                                                                 | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------- | -------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LOCAL_DB_PORT`               | No       | Derived from `DATABASE_URL`                             | `docker-compose.yml`                                                                        | Host-side Docker bind port for Postgres. `scripts/local-dev-up.sh` parses this from `DATABASE_URL` and passes it to compose; set manually only when running `docker compose` directly                                                                                                                                                                                                                                                                                                        |
| `FLAPJACK_DEV_DIR`            | No       | —                                                       | `local-dev-up.sh`, `local-signoff.sh`, `integration-up.sh`, `restart-region.sh`             | Explicit local `flapjack_dev` checkout path (repo root or `engine/` subdirectory). Shared lookup always tries this directory first when set. Restart-critical prerequisite callers continue through configured/default directory candidates when no binary is found here, then fall back to `PATH` only after directory candidates fail                                                                                                                                                      |
| `FLAPJACK_DEV_DIR_CANDIDATES` | No       | Built-in nearby checkout list                           | `local-dev-up.sh`, restart helpers, test/dev overrides                                      | Optional space-separated directory candidates checked after `FLAPJACK_DEV_DIR` and before built-in nearby defaults. Use this for host-specific layouts or tests; normal local workflows should set `FLAPJACK_DEV_DIR` only when autodiscovery misses                                                                                                                                                                                                                                         |
| `FLAPJACK_PORT`               | No       | `7700`                                                  | `local-dev-up.sh`                                                                           | Port flapjack binds to when started by the wrapper script                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `FLAPJACK_URL`                | No       | `http://127.0.0.1:$FLAPJACK_PORT`                       | `seed_local.sh`                                                                             | Flapjack base URL for optional local search-document seeding. Defaults to the same port as `local-dev-up.sh`; override when seeding against a non-local or non-default flapjack endpoint                                                                                                                                                                                                                                                                                                     |
| `LOCAL_DEV_FLAPJACK_URL`      | No       | —                                                       | API runtime                                                                                 | When set, `auto_provision_shared_vm()` bypasses cloud VM provisioning in local development and inserts a shared VM inventory row with provider `local`. This value is the fallback shared endpoint, but when `FLAPJACK_REGIONS` is set and `FLAPJACK_SINGLE_INSTANCE` is not `1`, the API derives a region-specific `http://127.0.0.1:<port>` URL from the matching region entry instead. Only loopback `http://` or `https://` URLs using `localhost`, `127.0.0.1`, or `[::1]` are accepted |
| `FLAPJACK_ADMIN_KEY`          | No       | `fj_local_dev_admin_key_000000000000` (wrapper default) | `local-dev-up.sh`, `api-dev.sh`, `integration-up.sh`, reliability scripts, API runtime      | Shared local flapjack admin key. In local dev when `ENVIRONMENT` is `local`/`dev`/`development` and `NODE_SECRET_BACKEND=memory`, wrappers default this so the API's in-memory node-secret manager and local flapjack enforce the same key. Prerequisite checks report only configured/redacted status (not raw values). Override only if every dependent local flapjack/API process is restarted with the same value                                                                        |
| `SKIP_EMAIL_VERIFICATION`     | No       | unset                                                   | API runtime                                                                                 | When set to any value, new signups are auto-verified locally instead of waiting for the SES email verification flow. Intended for local development and browser-unmocked test setup                                                                                                                                                                                                                                                                                                          |
| `NODE_SECRET_BACKEND`         | No       | `auto`                                                  | API runtime                                                                                 | Node secret backend selection (`auto`, `ssm`, `memory`, `disabled`). Set to `memory` in `.env.local` for local dev when AWS SSM is unavailable. The zero-dependency fallbacks only activate when `ENVIRONMENT` is also `local`/`dev`/`development`                                                                                                                                                                                                                                           |
| `FLAPJACK_REGIONS`            | No       | —                                                       | `local-dev-up.sh`, `seed_local.sh`, `start-metering.sh`, API runtime, strict signoff checks | Multi-region Flapjack topology as space-separated `region:port` pairs (e.g., `us-east-1:7700 eu-west-1:7701 eu-central-1:7702`). Ports must be numeric local loopback listeners. When set, `local-dev-up.sh` starts one Flapjack per entry, `seed_local.sh` maps inventory to per-region URLs, API local shared-VM auto-provisioning resolves the requested region to its matching port, and strict prerequisite checks reject malformed or duplicate region entries before HA proof runs    |
| `FLAPJACK_SINGLE_INSTANCE`    | No       | —                                                       | `local-dev-up.sh`, `seed_local.sh`, API runtime                                             | Set to `1` to force single-instance Flapjack mode even when `FLAPJACK_REGIONS` is set. In that mode, both `seed_local.sh` and API local-dev shared-VM auto-provisioning keep using the shared `FLAPJACK_URL` / `LOCAL_DEV_FLAPJACK_URL` fallback instead of region-specific ports                                                                                                                                                                                                            |
| `LOCAL_S3_PORT`               | No       | `8333`                                                  | `docker-compose.yml`, `local-dev-up.sh`                                                     | Host-side port for SeaweedFS S3 API                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `LOCAL_SMTP_PORT`             | No       | `1025`                                                  | `docker-compose.yml`                                                                        | Host-side port for Mailpit SMTP (unused — we use HTTP API)                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `LOCAL_MAILPIT_UI_PORT`       | No       | `8025`                                                  | `docker-compose.yml`, `local-dev-up.sh`                                                     | Host-side port for Mailpit web UI and HTTP API                                                                                                                                                                                                                                                                                                                                                                                                                                               |

## Local Seed & Signoff

Variables consumed by `scripts/seed_local.sh` and `scripts/local-signoff-commerce.sh`. The `SEED_USER_EMAIL` and `SEED_USER_PASSWORD` values also serve as fallback defaults for the `E2E_USER_*` preflight variables below.

| Variable                  | Required | Default                       | Consumed by                 | Description                                                                       |
| ------------------------- | -------- | ----------------------------- | --------------------------- | --------------------------------------------------------------------------------- |
| `SEED_USER_NAME`          | No       | `Test Developer`              | `seed_local.sh`             | Display name for the shared seeded user                                           |
| `SEED_USER_EMAIL`         | No       | `dev@example.com`             | `seed_local.sh`             | Email for the seeded test user (also used as `E2E_USER_EMAIL` fallback)           |
| `SEED_USER_PASSWORD`      | No       | `localdev-password-1234`      | `seed_local.sh`             | Password for the seeded test user (also used as `E2E_USER_PASSWORD` fallback)     |
| `SEED_FREE_USER_NAME`     | No       | `Free Plan User`              | `seed_local.sh`             | Display name for the free-plan seeded user                                        |
| `SEED_FREE_USER_EMAIL`    | No       | `free@example.com`            | `seed_local.sh`             | Email for the seeded free-plan user                                               |
| `SEED_FREE_USER_PASSWORD` | No       | `localdev-password-1234`      | `seed_local.sh`             | Password for the seeded free-plan user                                            |
| `SIGNOFF_MONTH`           | No       | current UTC month (`YYYY-MM`) | `local-signoff-commerce.sh` | Billing month passed to `/admin/billing/run` during strict local commerce signoff |

## E2E Browser Test Preflight

Variables consumed by `scripts/e2e-preflight.sh` and `web/playwright.config.ts` for browser-unmocked test runs. The preflight script loads `.env.local` via the shared env parser so these can resolve automatically after `scripts/seed_local.sh` and a local `.env.local` with `ADMIN_KEY` are in place.

| Variable            | Required | Default / Fallback                                 | Consumed by                                               | Description                                                                                                                                                                                                                                        |
| ------------------- | -------- | -------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `E2E_USER_EMAIL`    | No       | `SEED_USER_EMAIL` then `dev@example.com`           | `e2e-preflight.sh`, Playwright `auth.setup.ts`            | Email address of the seeded test user account                                                                                                                                                                                                      |
| `E2E_USER_PASSWORD` | No       | `SEED_USER_PASSWORD` then `localdev-password-1234` | `e2e-preflight.sh`, Playwright `auth.setup.ts`            | Password of the seeded test user account                                                                                                                                                                                                           |
| `E2E_ADMIN_KEY`     | No       | `ADMIN_KEY` from env or `.env.local`               | `e2e-preflight.sh`, Playwright `admin.auth.setup.ts`      | Admin key for admin panel browser tests. Falls back to `ADMIN_KEY` which is already set in `.env.local` for the API                                                                                                                                |
| `E2E_TEST_REGION`   | No       | `us-east-1`                                        | Playwright config                                         | Region with a running VM for index creation tests                                                                                                                                                                                                  |
| `DATABASE_URL`      | No\*     | —                                                  | `e2e-preflight.sh`, Playwright `onboarding.auth.setup.ts` | PostgreSQL connection string used by the `chromium:onboarding` setup to email-verify freshly signed-up test users via `psql`. Same value as the API's `DATABASE_URL`. \*Required for the onboarding lane; other Playwright projects do not need it |

## Staging Billing Dry Run

Variables consumed by `scripts/staging_billing_dry_run.sh`. This runner is intentionally staging-specific so it does not overload the local-dev `API_URL` or `STRIPE_WEBHOOK_URL` contracts with public staging semantics.

| Variable                     | Required | Default / Fallback | Consumed by                               | Description                                                                                                                                                                                                                                                                                |
| ---------------------------- | -------- | ------------------ | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `STAGING_API_URL`            | No\*     | —                  | `staging_billing_dry_run.sh`              | Base URL for the staging API used by the dry-run preflight. Must be an absolute `http://` or `https://` URL. `--run` probes `${STAGING_API_URL}/health`. \*Required for staging billing rehearsal                                                                                          |
| `STAGING_STRIPE_WEBHOOK_URL` | No\*     | —                  | `staging_billing_dry_run.sh`              | Public Stripe webhook URL for staging. Must use `https://` and target `/webhooks/stripe`. Missing or non-HTTPS values are classified as the Cloudflare/DNS blocker because Stripe requires a publicly reachable HTTPS endpoint for registered webhook delivery                             |
| `STRIPE_SECRET_KEY`          | No\*     | —                  | API runtime, `staging_billing_dry_run.sh` | Stripe sandbox secret key used by the staging API itself. For this rehearsal it must start with `sk_test_` or `rk_test_`; `sk_live_` and `rk_live_` are rejected so the dry-run path cannot be pointed at live mode by mistake. This runner intentionally requires canonical `STRIPE_SECRET_KEY` and does not fall back to `STRIPE_TEST_SECRET_KEY` because it validates the staging API's real runtime variable |

## Synthetic Traffic Seeder (Staging Contract)

Variables consumed by `scripts/launch/seed_synthetic_traffic.sh` and the Stage 5 live-proof seam in `scripts/tests/seed_synthetic_traffic_test.sh`.
This synthetic traffic seeder section documents the staging contract only.

### Execute mode contract (`seed_synthetic_traffic.sh`)

Execute mode reuses existing core environment variables from `preflight_env()`; no seeder-only execute env family is defined.

| Variable | Required for `--execute` | Description |
| --- | --- | --- |
| `DATABASE_URL` | Yes | PostgreSQL DSN used by proof queries and staging evidence checks. |
| `API_URL` | Yes | Admin API base URL used by tenant/index provisioning calls. |
| `ADMIN_KEY` | Yes | Admin auth key used for `/admin/*` requests. |
| `FLAPJACK_URL` | Yes | Default flapjack endpoint used for index provisioning fallback and direct traffic. |
| `FLAPJACK_API_KEY` | No (test/local override seam) | Optional override forwarded as `X-Algolia-API-Key` to direct-node calls. When unset, the seeder resolves the per-node admin key from SSM (`/fjcloud/{vm-hostname}/api-key`) on each `flapjack_url`, matching how the production scheduler authenticates against shared VMs. Operators on staging should leave this unset and rely on AWS SSM credentials in the caller environment. Tests still set `FLAPJACK_API_KEY` to bypass SSM. |
| `AWS_DEFAULT_REGION` | No (defaults `us-east-1`) | Used by the seeder's per-VM SSM lookup when `FLAPJACK_API_KEY` is unset. Caller IAM must allow `ssm:GetParameter` on `/fjcloud/{vm-hostname}/api-key` paths in this region. |

Selector boundary as implemented:
- Execute mode supports only `--tenant A`.
- `--tenant B`, `--tenant C`, and `--tenant all` remain descriptive in `--dry-run` and fail fast in execute mode as `unsupported selector`.
- In plain terms: --tenant B, --tenant C, and --tenant all are unsupported selectors for execute mode.

### Stage 5 live-proof harness gates (`seed_synthetic_traffic_test.sh`)

These gates are test-harness controls for the optional staging seam and are separate from `preflight_env()`:

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `RUN_SYNTHETIC_STAGING_LIVE_TESTS` | No | `0` | Must be `1` to enable the gated live staging seam. |
| `SYNTHETIC_STAGING_LIVE_ACK` | Conditionally | unset | Must equal `i-know-this-hits-staging` when live seam is enabled. |
| `SYNTHETIC_STAGING_ENV_FILE` | Conditionally | unset | Path to the env file sourced by the live seam before execute and `psql` checks. |
| `SYNTHETIC_STAGING_DURATION_MINUTES` | No | `5` | Optional execute-duration override used only by the live seam command wrapper. |

## SvelteKit Web Portal

| Variable                        | Required | Default                 | Description                                                        |
| ------------------------------- | -------- | ----------------------- | ------------------------------------------------------------------ |
| `API_BASE_URL`                  | No       | `http://localhost:3001` | Backend API URL for server-side API calls                          |
| `ADMIN_KEY`                     | Yes      | —                       | Same admin key as API (used server-side for admin panel API calls) |
| `ADMIN_SESSION_MAX_AGE_SECONDS` | No       | `28800` (8 hours)       | Admin session cookie lifetime                                      |
| `ENVIRONMENT`                   | No       | `development`           | Shown as badge in admin panel header                               |
| `SERVICE_STATUS`                | No       | `operational`           | Public status page status: `operational`, `degraded`, or `outage`  |
| `SERVICE_STATUS_UPDATED`        | No       | Current time            | ISO 8601 timestamp of last status update                           |

## VLM Judge (Product-Fit Tooling)

Variables consumed by `scripts/vlm/vlm_judge.sh`. The judge sends screenshots to the Anthropic Messages API for automated UI evaluation.

| Variable            | Required | Default | Description                                                                                                                                                                                                                                                                                   |
| ------------------- | -------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ANTHROPIC_API_KEY` | Yes      | —       | Anthropic API key for the VLM judge. Resolution order: (1) process environment, (2) `fjcloud/.secret/.env.secret`, (3) primary checkout `.secret/.env.secret` (for worktree invocations). The maintained key currently lives in `uff_dev/.secret/.env.secret` rather than `fjcloud`'s secret file |
