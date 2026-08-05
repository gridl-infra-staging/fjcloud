# Engine TLS Stage 3 first VM proof - 2026-08-05T11:16:33Z

## Scope

This Stage 3 proof launched one disposable staging EC2 instance directly from
`ami-07bff4ef03ac9ad00` using user-data rendered by this worktree, proved the
public TLS customer data plane with a real authenticated search, then published
the AMI through the guarded staging pointer owner.

Out-of-scope boundaries were preserved: prod pointer, prod floor VM
`i-072d4333322ffd0eb`, existing engine VMs, security-group rules, stored
`flapjack_url` values, deployed API provisioning path, and `ROADMAP.md` were not
changed. Product-path provisioning proof remains FR-5 work after FR-6 deploys
the current API renderer. ROADMAP CORRECTION REQUIRED: the exposure is plaintext
customer data-plane traffic, not an unauthenticated dashboard.

## Inputs

- HEAD after in-scope owner fix: `f6d33f5ac4b5b201d7ca0cabd2c04634f845c993`
- Renderer delta reason for direct launch:
  `infra/api/src/provisioner/cloud_init.rs | 116 +++++++++++++++++++++++++++-----`
  (`100 insertions(+), 16 deletions(-)`) between deployed staging
  `a384a42e6..origin/main`.
- AMI: `ami-07bff4ef03ac9ad00`; live describe required one account-owned
  `arm64`/`available` image tagged `Env=staging`, `managed-by=packer`,
  `service=fjcloud`.
- Proof id: `engine-tls-first-tls-vm-ab896e2c`
- Hostname and `node_id`: `vm-shared-ab896e2c.staging.flapjack.foo`
- Synthetic customer id: `ffdcea51-9661-49fb-85d4-fbdc1766fdd4`
- Launch inputs read live from SSM: subnet `subnet-03e3357684f12dcc8`,
  security group `sg-047734af5235c69af`, key pair `fjcloud-api-staging`,
  profile `fjcloud-instance-profile`, DNS domain `staging.flapjack.foo`.
- Instance profile role: `fjcloud-instance-role`; IAM simulation returned
  `allowed` for `ssm:GetParameter` on staging `database_url`, `dns_domain`,
  `internal_auth_token`, and `/fjcloud/<node_id>/api-key`.
- Preflight residue: zero `customers`, `vm_inventory`, `usage_records`, and
  joined `vm_host_metrics` rows; both node-key paths returned
  `ParameterNotFound`.

## Render And Launch

User-data was emitted through
`infra/api/src/services/provisioning/auto_provision.rs::build_user_data` by the
ignored owner test:

```text
cd infra && FJCLOUD_USER_DATA_EMIT_PATH=/tmp/engine-tls-first-tls-vm-ab896e2c_user_data.sh FJCLOUD_USER_DATA_CUSTOMER_ID=ffdcea51-9661-49fb-85d4-fbdc1766fdd4 FJCLOUD_USER_DATA_NODE_ID=vm-shared-ab896e2c.staging.flapjack.foo FJCLOUD_USER_DATA_REGION=us-east-1 FJCLOUD_USER_DATA_HOSTNAME=vm-shared-ab896e2c.staging.flapjack.foo cargo test -p api --lib emit_aws_user_data_for_operator -- --ignored
test result: ok. 1 passed; 0 failed
USER_DATA_SHA256=b38d275129d02c83b5ae4c159574c37432ce2a525a0f08645f8f8a4aaa70497e
```

Focused renderer tests at the render-time HEAD passed:

```text
cd infra && cargo test -p api --lib provisioner::cloud_init
test result: ok. 12 passed; 0 failed

cd infra && cargo test -p api --lib services::provisioning::auto_provision::tests::build_user_data
test result: ok. 11 passed; 0 failed
```

Node credential was stored only as a SecureString at
`/fjcloud/vm-shared-ab896e2c.staging.flapjack.foo/api-key`. Credential value was
not printed; its SHA-256 fingerprint was
`bcb121889e7944ed03e8875e630bebd3ff334f7f2d8b0c734ba9df1be78337ea`.

EC2 launch:

```text
INSTANCE_LAUNCHED=i-06faa1e204ff5cac5
PUBLIC_IP=54.80.38.229
SSM_PING_STATUS=Online
```

In-guest bootstrap proof:

```text
CLOUD_INIT_DONE=yes
METERING_STATE=inactive
FLAPJACK_STATE=active
CADDY_STATE=active
LOCAL_HEALTH_CODE=200
CADDYFILE_SHA256=c08495aaed0be8876389c43bd67f26ad3b3224c888bd2d6e9769019a83b9d735
vm-shared-ab896e2c.staging.flapjack.foo {
  reverse_proxy 127.0.0.1:7700
}
```

## DNS And TLS

Cloudflare was accessed with the canonical global-key headers from the project
secret source, without printing key values. Exact hostname lookup returned zero
records before create. Created record shape:

```text
CF_RECORD_ID=91a52bf27c78883e36cfb0ea00d35815
CF_RECORD_TYPE=A
CF_RECORD_NAME=vm-shared-ab896e2c.staging.flapjack.foo
CF_RECORD_CONTENT=54.80.38.229
CF_RECORD_TTL=300
CF_RECORD_PROXIED=false
DNS_PROPAGATED_IP=54.80.38.229
```

Customer-visible public data-plane assertions:

```text
HTTPS_HEALTH_CODE=200
PLAINTEXT_HEALTH_CODE=200
TLS_VERIFY_RETURN_CODE=0 (ok)
issuer=C=US, O=Let's Encrypt, CN=YE1
subject=CN=vm-shared-ab896e2c.staging.flapjack.foo
X509v3 Subject Alternative Name:
    DNS:vm-shared-ab896e2c.staging.flapjack.foo
Hostname vm-shared-ab896e2c.staging.flapjack.foo does match certificate
```

Authenticated HTTPS search proof used index `stage3_tls_ab896e2c` and a
hand-authored document with object id `stage3-doc-1`:

```text
SEARCH_CREATE_INDEX_STATUS=200
SEARCH_BATCH_STATUS=200
SEARCH_QUERY_STATUS=200
SEARCH_ASSERTION_STATUS=one_exact_hit
SEARCH_ASSERTION_OBJECT_ID=stage3-doc-1
SEARCH_ASSERTION_FIELD_BODY_MATCH=true
```

## Pointer Publication

Preflight pointer invariants:

```text
POINTER_PREFLIGHT_STAGING=ami-070b3dfb46c944d7e
POINTER_PREFLIGHT_PROD=ami-01deed1a1e04b3276
```

The first guarded execute restored the old pointer but failed host
reconciliation and stopped `fjcloud-api` fail-closed. Diagnosis showed the
owner script curled local `/version` immediately after restart. Commit
`f6d33f5ac4b5b201d7ca0cabd2c04634f845c993` added a bounded in-guest
`/version` readiness wait, and `bash scripts/tests/set_flapjack_ami_pointer_test.sh`
passed `74/74` with a regression assertion.

The fixed owner dry-run remained write-free:

```text
PLAN: would update /fjcloud/staging/aws_ami_id from ami-070b3dfb46c944d7e to ami-07bff4ef03ac9ad00, regenerate env, restart fjcloud-api, and prove served /version SHA
==> Dry-run: validation passed; no SSM writes or host commands performed
```

The fixed guarded execute succeeded:

```text
==> Target parameter: /fjcloud/staging/aws_ami_id
==> Selected API instances: i-0fbc6d6bbbc8bdc6d
==> Current pointer: ami-070b3dfb46c944d7e; requested pointer: ami-07bff4ef03ac9ad00; mode: execute
==> Pointer ami-07bff4ef03ac9ad00 and served /version SHA proved on all staging API instances
POINTER_POST_STAGING=ami-07bff4ef03ac9ad00
POINTER_POST_PROD=ami-01deed1a1e04b3276
```

Post-write pointer tests at HEAD passed:

```text
bash ops/terraform/tests_flapjack_ami_pointer_static.sh
Flapjack AMI pointer static contract: 10/10 passed.

bash ops/terraform/tests_flapjack_ami_pointer_plan.sh
Flapjack AMI pointer Terraform plan contract: 15/15 passed.

bash scripts/tests/set_flapjack_ami_pointer_test.sh
=== Results: 74 passed, 0 failed ===
```

## Teardown Proof

Teardown actions:

```text
DELETE_INDEX_STATUS=200
TERMINATE_TARGET=i-06faa1e204ff5cac5
TERMINATE_TARGET_STAGE_TAG=engine-tls-first-tls-vm-ab896e2c
TERMINATE_REQUEST_STATE=shutting-down
CF_DELETE_SUCCESS=true
SSM_DELETE_api-key=deleted
SSM_DELETE_api-key-previous=ParameterNotFound
```

Authoritative cleanup proofs:

```text
EC2_CAPTURED_INSTANCE_STATE=terminated
EC2_ACTIVE_STAGE_TAG_COUNT=0
CF_POST_DELETE_SUCCESS=true
CF_POST_DELETE_COUNT=0
DNS_POST_DELETE_EMPTY=yes
SSM_POST_DELETE_api-key=ParameterNotFound
SSM_POST_DELETE_api-key-previous=ParameterNotFound
DB_TEARDOWN_JSON={"usage_records": 0, "vm_host_metrics": 0, "vm_inventory": 0}
POINTER_FINAL_STAGING=ami-07bff4ef03ac9ad00
POINTER_FINAL_PROD=ami-01deed1a1e04b3276
```
