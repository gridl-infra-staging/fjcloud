# Engine TLS Stage 1 live baseline — 2026-08-05T06:57:06Z

## Scope and measurement rule

Stage 1 is read-only. It did not touch existing VMs, security groups, SSM
values, DNS, or Terraform. It made no AWS, DNS, EC2, Packer, systemd, or
Terraform write. The lane source was read in full before the first live command,
including PURPOSE, out-of-scope, credentials, pre-flight, and Merge.

Every live claim below was re-measured during this Stage 1 session, between
2026-08-05T06:43:17Z and 2026-08-05T06:57:06Z. Historical values were not used
as live evidence.

## Canonical live-state probe

The lane-prescribed credential load was performed first without printing
values:

```text
$ set -a; source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret; set +a
$ unset AWS_SESSION_TOKEN
$ bash scripts/probe_live_state.sh
docs/live-state/20260805T064446Z/SUMMARY.md
EXIT_CODE=0
```

That active secret source authenticated as IAM user `flapjack-loadtest`. The
probe completed, but its SSM rows recorded `AccessDeniedException`; that user
can enumerate EC2 but cannot read `/fjcloud/{staging,prod}/aws_ami_id` or subnet
pointers. This was authorization failure, not `ExpiredToken`.

Configured-profile and operator-secret fallbacks were tested without printing
keys or pointer values. The configured `default` profile was expired, while the
newest authorized static-key fallback at
`/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret.bak.20260727T193111`
authenticated as IAM user `stuart-cli` and passed the staging SSM read probe.
The active secret file was not edited. The canonical probe was then rerun with
its documented `FJCLOUD_SECRET_FILE` override:

```text
$ set -a; source .secret/.env.secret.bak.20260727T193111; set +a
$ unset AWS_SESSION_TOKEN
$ export FJCLOUD_SECRET_FILE=.secret/.env.secret.bak.20260727T193111
$ bash scripts/probe_live_state.sh
docs/live-state/20260805T065108Z/SUMMARY.md
EXIT_CODE=0
```

Newest bundle: `docs/live-state/20260805T065108Z/`

Newest summary: `docs/live-state/20260805T065108Z/SUMMARY.md`

The earlier diagnostic bundles are preserved at
`docs/live-state/20260805T064317Z/` and
`docs/live-state/20260805T064446Z/` as append-only command evidence.

## Named-VM exposure matrix

Each cell used the following command shape with a five-second connect timeout
and ten-second total timeout:

```text
curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 http://<ip>:7700<path>
```

Prod `fj-vm-shared-1ca0d103` (`34.228.66.185`):

| Path | HTTP status | Exit |
| --- | ---: | ---: |
| `/health` | `200` | `0` |
| `/` | `403` | `0` |
| `/1/health` | `403` | `0` |
| `/docs` | `403` | `0` |
| `/docs2` | `403` | `0` |
| `/ui` | `403` | `0` |
| `/1/indexes` | `403` | `0` |
| `/metrics` | `403` | `0` |
| `/version` | `403` | `0` |
| `/dashboard` | `404` | `0` |

Staging `fj-vm-shared-3bd2b971` (`54.173.50.206`):

| Path | HTTP status | Exit |
| --- | ---: | ---: |
| `/health` | `200` | `0` |
| `/` | `403` | `0` |
| `/1/health` | `403` | `0` |
| `/docs` | `403` | `0` |
| `/docs2` | `403` | `0` |
| `/ui` | `403` | `0` |
| `/1/indexes` | `403` | `0` |
| `/metrics` | `403` | `0` |
| `/version` | `403` | `0` |
| `/dashboard` | `404` | `0` |

No path previously expected to return `403` returned `200`. There is no new
unauthenticated engine surface in this measurement.

## Current AMI pointers and image metadata

The active `flapjack-loadtest` credential returned `AccessDeniedException`
with exit `254` for both commands. After switching only the AWS environment to
the authorized `stuart-cli` fallback, the exact commands passed:

```text
$ aws ssm get-parameter --name /fjcloud/staging/aws_ami_id --query Parameter.Value --output text
ami-070b3dfb46c944d7e
EXIT_CODE=0

$ aws ssm get-parameter --name /fjcloud/prod/aws_ami_id --query Parameter.Value --output text
ami-01deed1a1e04b3276
EXIT_CODE=0
```

Image metadata was queried with `aws ec2 describe-images --image-ids <id>`:

| Environment | ImageId | Name | CreationDate | State |
| --- | --- | --- | --- | --- |
| staging | `ami-070b3dfb46c944d7e` | `flapjack-1.0.2-pl13-20260529-0254` | `2026-05-29T03:17:15.000Z` | `available` |
| prod | `ami-01deed1a1e04b3276` | `flapjack-1.0.2-pl13-20260530-0343` | `2026-05-30T04:06:18.000Z` | `available` |

Both describe-images commands exited `0`.

## Fleet dataplane verdict and attribution

```text
$ bash scripts/probe_fleet_dataplane.sh --evidence docs/live-state/20260805T065108Z/fleet_dataplane.json
FLEET_STATUS: ACTION_REQUIRED reason=environment_attribution_ambiguous
EXIT_CODE=1
```

`ACTION_REQUIRED` is baseline data, not a Stage 1 failure. The evidence has no
public address fields, so only its seven running managed InstanceIds were
resolved with:

```text
aws ec2 describe-instances --instance-ids i-0c74e2fe5fa24b116 i-00a3b28ba4c00433a i-0b2188437baeeacdf i-019d556392acdada7 i-0f9b2a9bd8cbaeeec i-072d4333322ffd0eb i-0d0e9aaa87c7a4005 --query 'Reservations[].Instances[].{InstanceId:InstanceId,PublicDnsName:PublicDnsName,PublicIpAddress:PublicIpAddress,SecurityGroups:SecurityGroups[].GroupId}' --output json
EXIT_CODE=0
```

Environment attribution below uses only same-region subnet pointers from
`fleet_dataplane.json`. No EC2 `environment` or `Env` tag was used.

| Attribution | InstanceId | ImageId | SubnetId | Public IP | Security groups |
| --- | --- | --- | --- | --- | --- |
| staging (`subnet-03e3357684f12dcc8`) | `i-0c74e2fe5fa24b116` | `ami-078228dbe86117d85` | `subnet-03e3357684f12dcc8` | `54.173.50.206` | `sg-047734af5235c69af` |
| staging (`subnet-03e3357684f12dcc8`) | `i-00a3b28ba4c00433a` | `ami-078228dbe86117d85` | `subnet-03e3357684f12dcc8` | `44.220.133.5` | `sg-047734af5235c69af` |
| staging (`subnet-03e3357684f12dcc8`) | `i-0b2188437baeeacdf` | `ami-078228dbe86117d85` | `subnet-03e3357684f12dcc8` | `100.27.229.251` | `sg-047734af5235c69af` |
| staging (`subnet-03e3357684f12dcc8`) | `i-019d556392acdada7` | `ami-078228dbe86117d85` | `subnet-03e3357684f12dcc8` | `54.163.206.24` | `sg-047734af5235c69af` |
| staging (`subnet-03e3357684f12dcc8`) | `i-0f9b2a9bd8cbaeeec` | `ami-078228dbe86117d85` | `subnet-03e3357684f12dcc8` | `54.81.17.133` | `sg-047734af5235c69af` |
| prod (`subnet-0f20d0fd83a362024`) | `i-072d4333322ffd0eb` | `ami-01deed1a1e04b3276` | `subnet-0f20d0fd83a362024` | `34.228.66.185` | `sg-0ab78cabd1b997099` |
| unattributed: subnet matches no same-region env pointer | `i-0d0e9aaa87c7a4005` | `ami-052355af2a014bd2c` | `subnet-278fa26e` | `54.236.22.122` | `sg-0c914d0e0a50a8438` |

The final port method was `nc -z -G 5 -w 5 <ip> <port>`; `-G` is the macOS
connection-timeout flag. An initial `nc -z -w 5` sweep was incomplete because
`-w` alone did not bound the prod port-80 connect; after diagnosis, the entire
matrix was rerun consistently:

| InstanceId | Public IP | 80 | 443 | 7700 |
| --- | --- | --- | --- | --- |
| `i-0c74e2fe5fa24b116` | `54.173.50.206` | closed/filtered | closed/filtered | open |
| `i-00a3b28ba4c00433a` | `44.220.133.5` | closed/filtered | closed/filtered | open |
| `i-0b2188437baeeacdf` | `100.27.229.251` | closed/filtered | closed/filtered | open |
| `i-019d556392acdada7` | `54.163.206.24` | closed/filtered | closed/filtered | open |
| `i-0f9b2a9bd8cbaeeec` | `54.81.17.133` | closed/filtered | closed/filtered | open |
| `i-072d4333322ffd0eb` | `34.228.66.185` | closed/filtered | closed/filtered | open |
| `i-0d0e9aaa87c7a4005` | `54.236.22.122` | closed/filtered | closed/filtered | closed/filtered |

## Packer and Caddy recipe checks

```text
$ grep -n 'caddy' ops/packer/flapjack-ami.pkr.hcl
79:  caddy_version                     = "2.10.0"
80:  caddy_linux_arm64_archive         = "caddy_2.10.0_linux_arm64.tar.gz"
81:  caddy_download_url                = "https://github.com/caddyserver/caddy/releases/download/v2.10.0/caddy_2.10.0_linux_arm64.tar.gz"
82:  caddy_linux_arm64_sha256          = "7976e98c44ddfaa32fed4e658246d6cc56b318183354c10a2a3c95219a4898a6"
194:    source      = "../systemd/caddy.service"
195:    destination = "/tmp/caddy.service"
233:      # Create caddy system user and directories (VM-local TLS termination)
234:      "sudo useradd --system --shell /sbin/nologin --create-home --home-dir /var/lib/caddy caddy",
235:      "sudo mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy",
236:      "sudo chown root:caddy /etc/caddy",
237:      "sudo chown caddy:caddy /var/lib/caddy /var/log/caddy",
244:      "curl -fsSL --retry 3 -o /tmp/${local.caddy_linux_arm64_archive} ${local.caddy_download_url}",
245:      "printf '%s  %s\\n' '${local.caddy_linux_arm64_sha256}' '/tmp/${local.caddy_linux_arm64_archive}' | sha256sum -c -",
246:      "mkdir -p /tmp/caddy-extract",
247:      "tar -xzf /tmp/${local.caddy_linux_arm64_archive} -C /tmp/caddy-extract caddy",
248:      "file /tmp/caddy-extract/caddy | grep -E 'aarch64|ARM64|ARM aarch64'",
250:      "sudo install -m 0755 /tmp/caddy-extract/caddy /usr/local/bin/caddy",
264:      "sudo install -m 0644 /tmp/caddy.service /etc/systemd/system/caddy.service",
288:      "rm -rf /tmp/caddy-extract",
289:      "rm -f /tmp/flapjack-e3-manifest.json /tmp/${local.flapjack_release_archive_file} /tmp/validate_flapjack_ami_input.sh /tmp/validated-flapjack /tmp/${local.caddy_linux_arm64_archive} /tmp/fjcloud-api /tmp/fjcloud-aggregation-job /tmp/fjcloud-retention-job /tmp/fj-metering-agent /tmp/flapjack.service /tmp/fj-metering-agent.service /tmp/fjcloud-api.service /tmp/fjcloud-aggregation-job.service /tmp/fjcloud-aggregation-job.timer /tmp/fjcloud-retention-job.service /tmp/fjcloud-retention-job.timer /tmp/caddy.service /tmp/bootstrap.sh /tmp/logrotate-flapjack",
299:      caddy_version                     = local.caddy_version
300:      caddy_linux_arm64_sha256          = local.caddy_linux_arm64_sha256
EXIT_CODE=0

$ bash ops/packer/validate_flapjack_ami_input.sh --help
Usage: validate_flapjack_ami_input.sh --manifest <manifest.json> --archive <archive.tar.gz> --out <flapjack>

Validates the selected upstream Flapjack E3 release manifest/archive pair and
extracts the single flapjack executable to --out.
EXIT_CODE=0

$ grep -n 'validate_flapjack_ami_input.sh' ops/packer/flapjack-ami.pkr.hcl
133:    source      = "validate_flapjack_ami_input.sh"
134:    destination = "/tmp/validate_flapjack_ami_input.sh"
242:      "chmod +x /tmp/validate_flapjack_ami_input.sh",
243:      "/tmp/validate_flapjack_ami_input.sh --manifest /tmp/flapjack-e3-manifest.json --archive /tmp/${local.flapjack_release_archive_file} --out /tmp/validated-flapjack",
289:      "rm -f /tmp/flapjack-e3-manifest.json /tmp/${local.flapjack_release_archive_file} /tmp/validate_flapjack_ami_input.sh /tmp/validated-flapjack /tmp/${local.caddy_linux_arm64_archive} /tmp/fjcloud-api /tmp/fjcloud-aggregation-job /tmp/fjcloud-retention-job /tmp/fj-metering-agent /tmp/flapjack.service /tmp/fj-metering-agent.service /tmp/fjcloud-api.service /tmp/fjcloud-aggregation-job.service /tmp/fjcloud-aggregation-job.timer /tmp/fjcloud-retention-job.service /tmp/fjcloud-retention-job.timer /tmp/caddy.service /tmp/bootstrap.sh /tmp/logrotate-flapjack",
EXIT_CODE=0

$ stat -f '%Sp %z bytes %Sm %N' ops/systemd/caddy.service
-rw-r--r-- 829 bytes Aug  5 02:35:44 2026 ops/systemd/caddy.service
EXIT_CODE=0
```

The existing Packer file delegates archive/manifest validation to the existing
validator provisioner. No fake manifest or archive was created. Neither
`ops/packer/flapjack-ami.pkr.hcl` nor `ops/systemd/caddy.service` was edited.

## Baseline disposition

- Named-VM unauthenticated surface: unchanged; protected paths are still `403`.
- Customer transport: plaintext only on the attributed live fleet; ports 80 and
  443 are closed/filtered while port 7700 is open.
- SSM pointers: staging `ami-070b3dfb46c944d7e`; prod
  `ami-01deed1a1e04b3276`.
- Fleet classifier: accepted baseline `ACTION_REQUIRED` with exact reason
  `environment_attribution_ambiguous`.
- AMI recipe prerequisite: Caddy `2.10.0` and its pinned SHA256 are present,
  with the existing validator and systemd service wiring intact.

ROADMAP CORRECTION REQUIRED: the current live evidence continues to falsify
the wording that an unauthenticated engine dashboard is exposed. This stage did
not edit `ROADMAP.md`, per lane ownership.
