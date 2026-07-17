# Deployment Lifecycle

## VM provisioning flow

```
API call (POST /deployments or auto-provision on first index)
  → ProvisioningService.provision()
    → SSM: create node API key
    → EC2: RunInstances (AMI, user-data, IAM profile, IMDS tags)
    → Route53: create DNS A record (vm-<id>.flapjack.foo)
    → DB: deployment status = "provisioning"
  → HealthMonitor polls /health every 60s
    → On first successful health check: status = "running"
    → After 3 consecutive failures: status = "unhealthy"
```

## Manually provisioning a VM

Normally VMs are auto-provisioned when a customer creates their first index in a region. To manually provision:

```bash
curl -X POST https://api.flapjack.foo/admin/deployments \
  -H "X-Admin-Key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "customer_id": "<tenant-uuid>",
    "region": "us-east-1",
    "instance_type": "t3.medium"
  }'
```

## Stopping a VM

Stops the EC2 instance but preserves data. Customer indexes are temporarily unavailable.

```bash
curl -X POST https://api.flapjack.foo/admin/deployments/<id>/stop \
  -H "X-Admin-Key: $ADMIN_KEY"
```

## Starting a stopped VM

```bash
curl -X POST https://api.flapjack.foo/admin/deployments/<id>/start \
  -H "X-Admin-Key: $ADMIN_KEY"
```

## Terminating a VM

**Pre-flight checks:**
1. Verify no critical indexes are on the VM (check `/admin/customers/<customer-id>` → Indexes tab)
2. If indexes exist, either migrate them or inform the customer

**Terminate:**
```bash
curl -X DELETE https://api.flapjack.foo/admin/deployments/<id> \
  -H "X-Admin-Key: $ADMIN_KEY"
```

This will:
- Terminate the EC2 instance
- Delete the DNS record from Route53
- Delete the node API key from SSM
- Set deployment status to "terminated"

**Note**: `DELETE` is idempotent — calling it on an already-terminated or externally-terminated VM succeeds without error (matches AWS TerminateInstances behavior).

## Health monitoring

- `HealthMonitor` runs as a background service, polling `/health` on all active VMs every 60s
- After 3 consecutive failures (`UNHEALTHY_THRESHOLD`), deployment is marked unhealthy
- A Critical alert fires on healthy → unhealthy transition
- An Info alert fires on unhealthy → healthy recovery
- Provisioning deployments that haven't become healthy yet do NOT trigger alerts (expected during startup)
