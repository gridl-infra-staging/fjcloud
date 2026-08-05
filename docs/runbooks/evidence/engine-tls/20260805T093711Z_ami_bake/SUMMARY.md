# Engine TLS AMI Bake Evidence

Captured on 2026-08-05 in `us-east-1`. This Stage 2 operation baked and
registered an AMI, proved its contents through a throwaway guest, and did not
move either environment's AMI pointer. No product provisioning or Terraform
operation was used.

## Inputs and pre-bake state

The upstream E3 inputs were the manifest/archive pair named
`flapjack-aarch64-unknown-linux-musl.manifest.json` and
`flapjack-aarch64-unknown-linux-musl.tar.gz` from the upstream
`engine/target/e3-stage2-20260805/` release directory. The repo-owned validator
accepted that pair before Packer ran:

```text
manifest_sha256=e3d8188fcc2b4f033648a225a42da29bacd6f385ae8429955931073b6bb36e4a
archive_sha256=35e4adab4ca2845e09196ebf868640cd6ef4d6061b1d1d3716255bd95598fba2
binary_sha256=e2140ee8759056b4477036b6a2e3b48139ab2abbf3778cc3d453926bf52393c1
release_identifier=1.0.11
revision=584ed0be4b0d7011c201ebb7e7b845f43c5cbab4
workspace_digest=79244c4a922429b3c53807fdf1299186949e139f8d5b144995cf5d7acac13375
target=aarch64-unknown-linux-musl
profile=release
dirty=null
```

At 2026-08-05T09:01:35Z, immediately before the bake, the pointer reads were:

```text
/fjcloud/staging/aws_ami_id = ami-070b3dfb46c944d7e
/fjcloud/prod/aws_ami_id    = ami-01deed1a1e04b3276
```

The fjcloud-owned registry slice contained these available images and no
`flapjack-1.0.11-*` image:

| AMI | Name | Created | Environment tag |
| --- | --- | --- | --- |
| `ami-078228dbe86117d85` | `flapjack-0.1.0-20260408-1901` | 2026-04-08T19:25:06.000Z | staging |
| `ami-0df77f1c103ce1be7` | `flapjack-0.0.18-beta-20260516-0026` | 2026-05-16T00:48:51.000Z | staging |
| `ami-070b3dfb46c944d7e` | `flapjack-1.0.2-pl13-20260529-0254` | 2026-05-29T03:17:15.000Z | staging |
| `ami-01deed1a1e04b3276` | `flapjack-1.0.2-pl13-20260530-0343` | 2026-05-30T04:06:18.000Z | prod |
| `ami-0a3f176fb3d489ffa` | `flapjack-1.0.10-20260723-1937` | 2026-07-23T20:01:55.000Z | staging |

## Bake and registration

After `packer init .`, the bake ran from `ops/packer` with:

```bash
packer build \
  -var 'flapjack_manifest_path=<upstream-e3-manifest.json>' \
  -var 'flapjack_archive_path=<upstream-e3-archive.tar.gz>' \
  -var 'env=staging' \
  flapjack-ami.pkr.hcl
```

Packer completed successfully. Its manifest post-processor recorded:

```text
artifact_id=us-east-1:ami-07bff4ef03ac9ad00
packer_run_uuid=e05fd106-cb40-ee5d-f76e-6f41088b0f60
caddy_version=2.10.0
caddy_linux_arm64_sha256=7976e98c44ddfaa32fed4e658246d6cc56b318183354c10a2a3c95219a4898a6
flapjack_release_identifier=1.0.11
flapjack_upstream_manifest_sha256=e3d8188fcc2b4f033648a225a42da29bacd6f385ae8429955931073b6bb36e4a
flapjack_upstream_archive_sha256=35e4adab4ca2845e09196ebf868640cd6ef4d6061b1d1d3716255bd95598fba2
```

The post-bake EC2 read returned:

```text
ImageId:  ami-07bff4ef03ac9ad00
Name:     flapjack-1.0.11-20260805-0901
Created:  2026-08-05T09:26:01.000Z
State:    available
Snapshot: snap-069cba33cf86ce3a9
Tags:     service=fjcloud, Env=staging, Name=flapjack-1.0.11, managed-by=packer
```

The Packer builder instance `i-0f2a5b04c290d4a3e` was terminated, and Packer
reported deletion of its temporary security group and key pair.

## New-AMI live guest proof

Fresh placement values were read from the staging SSM parameters. A
`t4g.small` throwaway, `i-0fd0769b2ee8d3251`, was launched from the new AMI
with `stage=engine-tls-ami-bake`, `proof=positive`, the staging instance
profile, IMDSv2 required, and no `customer_id` tag. EC2 reached `running` and
SSM reached `Online`. Direct SSM command
`717ff994-8767-48f4-869c-53c13214875e` returned `Success`:

```text
# /etc/systemd/system/caddy.service
[Unit]
Description=Caddy TLS Reverse Proxy
After=network-online.target flapjack.service
Requires=flapjack.service
ConditionPathExists=/etc/caddy/Caddyfile

[Service]
Type=exec
User=caddy
Group=caddy
WorkingDirectory=/var/lib/caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force

v2.10.0 h1:fonubSaQKF1YANl8TXqGcn4IbIRUDdfAkpcsfI/vX5U=
CADDY_EXECUTABLE=yes
caddy.service: inactive (dead)
```

The inactive service is expected on a one-off guest without a provisioned
`/etc/caddy/Caddyfile`; the unit deliberately has `ConditionPathExists`.
`ops/packer/flapjack-ami.pkr.hcl:249-250` owns installation of the Flapjack and
Caddy binaries, and `ops/systemd/caddy.service:15` owns the observed start
command.

The same SSM command returned the packaged Flapjack identity:

```text
e2140ee8759056b4477036b6a2e3b48139ab2abbf3778cc3d453926bf52393c1  /usr/local/bin/flapjack
{"schemaVersion":1,"version":"1.0.11","revision":"584ed0be4b0d7011c201ebb7e7b845f43c5cbab4","revisionKnown":true,"dirty":null,"dirtyKnown":false,"workspaceDigest":"79244c4a922429b3c53807fdf1299186949e139f8d5b144995cf5d7acac13375","profile":"release","target":"aarch64-unknown-linux-musl","features":["analytics","axum-support","decompound","memory-stats","openapi","s3-snapshots"],"capabilities":{"vectorSearch":false,"vectorSearchLocal":false}}
FLAPJACK_HEALTH_SKIPPED=service_inactive
```

The installed binary hash exactly matches the validator output, and every
build-identity field matches the accepted manifest. Local health was correctly
skipped because this unprovisioned proof guest did not start Flapjack.
`scripts/probe_flapjack_build_identity.sh:25-33` does not apply to this one-off
instance: its remote contract accepts the named `staging` or `prod` target and
routes through the corresponding host wrapper. Direct SSM preserves the
one-off instance identity required by this stage.

## Old-pointer negative control

A second `t4g.small` throwaway, `i-0df4913290bd653bd`, used the same fresh
placement and metadata shape but booted the pre-bake staging pointer AMI
`ami-070b3dfb46c944d7e`, with `proof=negative`. It reached EC2 `running` and SSM
`Online`. Direct SSM command `68dc1f98-f5d1-47a9-b8b1-8fe7f2abec4a` returned
`Success` only after asserting all expected absences:

```text
No files found for caddy.service.
/usr/local/bin/caddy: No such file or directory
Unit caddy.service could not be found.
NEGATIVE_RESULTS unit_rc=1 version_rc=127 executable=no status_rc=4
NEGATIVE_ASSERTIONS caddy_unit=absent caddy_binary=absent caddy_service=absent
```

This control proves the positive result came from the new AMI rather than the
placement or probe procedure.

## Cleanup and pointer non-mutation

Termination was guarded by an exact `stage=engine-tls-ami-bake` match and the
absence of `customer_id`. At 2026-08-05T09:37:11Z the terminal-state read was:

```text
i-0f2a5b04c290d4a3e  terminated  (Packer builder)
i-0fd0769b2ee8d3251  terminated  (positive proof)
i-0df4913290bd653bd  terminated  (negative control)
active instances with stage=engine-tls-ami-bake: []
```

The final pointer reads exactly matched the pre-bake values:

```text
/fjcloud/staging/aws_ami_id = ami-070b3dfb46c944d7e
/fjcloud/prod/aws_ami_id    = ami-01deed1a1e04b3276
```

Therefore Stage 2 registered and proved `ami-07bff4ef03ac9ad00` without moving
an environment pointer or leaving a throwaway instance running.
