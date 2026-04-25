# fjcloud Operations

Scripts and templates for building, deploying, and managing flapjack VM images.

## Directory Layout

```
ops/
├── packer/
│   └── flapjack-ami.pkr.hcl    # Packer template for Amazon Linux 2023 AMI
├── systemd/
│   ├── flapjack.service         # flapjack engine systemd unit
│   └── fj-metering-agent.service  # metering agent systemd unit
├── user-data/
│   └── bootstrap.sh             # cloud-init bootstrap script
└── README.md
```

## Building AMIs

### Prerequisites

- [Packer](https://developer.hashicorp.com/packer) >= 1.9
- AWS credentials with EC2 + AMI permissions
- Pre-built Linux ARM64 binaries in `ops/build/` for:
  - `flapjack`
  - `fjcloud-api`
  - `fjcloud-aggregation-job`
  - `fj-metering-agent`

### Build steps

```bash
# 1. Place binaries
mkdir -p ops/build
cp /path/to/flapjack ops/build/flapjack
cp /path/to/fjcloud-api ops/build/fjcloud-api
cp /path/to/fjcloud-aggregation-job ops/build/fjcloud-aggregation-job
cp /path/to/fj-metering-agent ops/build/fj-metering-agent

# 2. Initialize Packer plugins
cd ops/packer
packer init .

# 3. Build AMI
packer build -var 'flapjack_version=0.1.0' flapjack-ami.pkr.hcl

# 4. Note the AMI ID from output (also in flapjack-ami-manifest.json)
```

### Building for a different region

```bash
packer build \
  -var 'flapjack_version=0.1.0' \
  -var 'region=eu-west-1' \
  flapjack-ami.pkr.hcl
```

To make the AMI available in multiple regions, copy it after building:

```bash
aws ec2 copy-image \
  --source-region us-east-1 \
  --source-image-id ami-0abc123... \
  --region eu-west-1 \
  --name "flapjack-0.1.0-copy"
```

## Updating Images

1. Build new binaries from the latest source
2. Run `packer build` with a new version tag
3. Update `AWS_AMI_ID` in the fjcloud API server config
4. New deployments will use the updated AMI; existing VMs are not affected

To update an existing VM, terminate it and create a new deployment.

## VM Lifecycle

### How provisioning works

1. Customer creates a deployment via `POST /deployments`
2. API creates a DB record (status=`provisioning`) and spawns a background task
3. Background task creates a per-node API key in SSM (`/fjcloud/{node_id}/api-key`)
4. Background task calls `AwsVmProvisioner.create_vm()` which launches an EC2 instance with the configured AMI (IMDS tags enabled)
5. EC2 user-data runs at first boot:
   - Reads `customer_id` and `node_id` from IMDS instance tags (no API call needed)
   - Fetches secrets from AWS SSM Parameter Store
   - Writes env files to `/etc/flapjack/`
   - Starts `flapjack` and `fj-metering-agent` systemd services
5. Health monitor detects flapjack responding at `https://vm-{id}.flapjack.foo/health`
6. Deployment status transitions to `running`

### SSH access

SSH via the key pair configured in `AWS_KEY_PAIR_NAME`:

```bash
ssh -i ~/.ssh/fjcloud-key.pem ec2-user@vm-abcd1234.flapjack.foo
```

### Checking service status

```bash
sudo systemctl status flapjack
sudo systemctl status fj-metering-agent
sudo journalctl -u flapjack -f
sudo journalctl -u fj-metering-agent -f
```

## AWS SSM Parameters

The bootstrap script reads these SSM parameters at boot:

| Parameter | Description | Created by |
|-----------|-------------|------------|
| `/fjcloud/{environment}/database_url` | PostgreSQL connection string | Manual (one-time setup) |
| `/fjcloud/{node_id}/api-key` | Flapjack API key for this node | Provisioning service (automatic) |

Set up the environment-scoped DB URL parameter before launching any VMs:

```bash
aws ssm put-parameter --name "/fjcloud/staging/database_url" \
  --type SecureString --value "postgres://..."
```

Per-node API keys are created automatically by the provisioning service (via `SsmNodeSecretManager`) before each VM is launched, and deleted on termination.

## IAM Instance Profile

VMs need an IAM instance profile to access SSM parameters at boot. Create it using the Terraform config:

```bash
cd ops/iam
terraform init
terraform plan
terraform apply
```

Then set the environment variable for the API server:

```bash
export AWS_INSTANCE_PROFILE_NAME="fjcloud-instance-profile"
```

The instance profile grants `ssm:GetParameter` on `/fjcloud/*` parameters.

## Ports

| Port | Protocol | Service |
|------|----------|---------|
| 443  | TCP      | HTTPS (TLS terminated by flapjack ACME) |
| 7700 | TCP      | Flapjack HTTP API |
| 9091 | TCP      | Metering agent health endpoint |
| 22   | TCP      | SSH |
