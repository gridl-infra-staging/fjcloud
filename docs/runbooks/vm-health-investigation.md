# VM Health Investigation

## Identifying unhealthy VMs

1. **Admin panel**: Navigate to `/admin/fleet` — look for VMs with red health badges
2. **Admin API**: `GET /admin/fleet` returns all deployments with `health_status` field
3. **Alerts**: Critical alerts fire when a deployment transitions healthy → unhealthy (3 consecutive failures via `HealthMonitor`)

## Investigation steps

### 1. Check the flapjack process

```bash
ssh -i <key> ec2-user@vm-<id>.flapjack.foo
sudo systemctl status flapjack
sudo journalctl -u flapjack --since "1 hour ago" --no-pager
```

### 2. Check disk space

```bash
df -h
du -sh /var/lib/flapjack/data/*
```

### 3. Check memory

```bash
free -h
top -b -n1 | head -20
```

### 4. Check network connectivity

```bash
curl -s http://localhost:8080/health
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/1/indexes
```

### 5. Check metering agent

```bash
sudo systemctl status metering-agent
sudo journalctl -u metering-agent --since "1 hour ago" --no-pager
```

## Common causes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| flapjack process not running | OOM kill or crash | Restart: `sudo systemctl restart flapjack` |
| Disk >90% full | Index data growth | Terminate and replace VM with larger instance |
| Health endpoint returns 5xx | Internal flapjack error | Check flapjack logs, restart if needed |
| Connection refused on port 8080 | Process crashed or port conflict | Restart, check for port conflicts |
| DNS not resolving | Route53 record missing | Re-run DNS setup via admin API |

## Remediation

### Restart the flapjack process
```bash
sudo systemctl restart flapjack
# Wait 30s then verify
curl -s http://localhost:8080/health
```

### Terminate and replace VM
1. Ensure no critical indexes are on the VM (check admin panel customer detail)
2. `DELETE /admin/deployments/<id>` — terminates the VM and cleans up DNS
3. Customer's next index creation will auto-provision a new VM

### Escalation
If the issue is not resolved by restart or replacement:
1. Post in #ops Slack channel with deployment ID, region, and symptoms
2. Attach relevant logs from `journalctl`
3. Tag the on-call engineer
