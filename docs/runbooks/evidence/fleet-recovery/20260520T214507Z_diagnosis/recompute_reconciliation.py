import csv, json, os, sys
bundle=sys.argv[1]
fleet=json.load(open(f"{bundle}/10_admin_fleet.json","r",encoding="utf-8"))
ec2=json.load(open(f"{bundle}/11_ec2_instances.json","r",encoding="utf-8"))
vm_rows=list(csv.DictReader(open(f"{bundle}/23_vm_inventory.csv","r",encoding="utf-8")))
provisioning_rows=list(csv.DictReader(open(f"{bundle}/25_customer_deployments_provisioning.csv","r",encoding="utf-8")))
health_rows=json.load(open(f"{bundle}/26_vm_http_health_probe.json","r",encoding="utf-8"))
health_by_host={r.get("hostname"):r for r in health_rows if r.get("hostname")}
vm_by_host={r.get("hostname"):r for r in vm_rows if r.get("hostname")}

def normalize_provider_vm_id(provider, provider_vm_id):
    if not provider_vm_id:
        return ""
    if ":" in provider_vm_id:
        prefix, raw = provider_vm_id.split(":",1)
        if prefix == provider and raw:
            return raw
    return provider_vm_id

ec2_by_id={r.get("InstanceId"):r for r in ec2 if r.get("InstanceId")}
ec2_by_host={}
for r in ec2:
    n=r.get("Name") or ""
    h=n[3:] if n.startswith("fj-") else n
    if h:
        ec2_by_host[h]=r
rows=[]
for dep in provisioning_rows:
    provider=dep.get("vm_provider") or ""
    raw=dep.get("provider_vm_id") or ""
    norm=normalize_provider_vm_id(provider, raw)
    host=dep.get("hostname") or ""
    vm=vm_by_host.get(host)
    ec2_id=ec2_by_id.get(norm)
    ec2_host=ec2_by_host.get(host)
    ec2_match=ec2_id or ec2_host
    health=health_by_host.get(host)
    rows.append({
        "deployment_id":dep.get("id"),"customer_id":dep.get("customer_id"),"status":dep.get("status"),"created_at":dep.get("created_at"),
        "vm_provider":provider,"provider_vm_id_raw":raw,"provider_vm_id_normalized":norm,"hostname":host,
        "vm_inventory_id":(vm or {}).get("id"),"vm_inventory_status":(vm or {}).get("status"),
        "ec2_instance_id":(ec2_match or {}).get("InstanceId"),"ec2_state":(ec2_match or {}).get("State"),
        "ec2_match_source":"provider_vm_id" if ec2_id else ("hostname" if ec2_host else "none"),
        "http_health_code":(health or {}).get("http_code"),"http_health_is_healthy":(health or {}).get("is_healthy")
    })
missing=[]
for vm in vm_rows:
    host=vm.get("hostname") or ""
    if host and host not in ec2_by_host:
        missing.append({"vm_inventory_id":vm.get("id"),"hostname":host,"provider":vm.get("provider"),"status":vm.get("status")})
dead=[r for r in rows if r.get("ec2_state")=="running" and str(r.get("http_health_code"))!="200"]
out={"counts":{"fleet_rows":len(fleet),"ec2_instances_non_terminated":len(ec2),"vm_inventory_rows":len(vm_rows),"provisioning_deployments":len(provisioning_rows),"dead_but_running_deployments":len(dead),"inventory_rows_without_nonterminated_ec2_match":len(missing)},"reconciliation_rows":rows,"inventory_missing_ec2":missing,"dead_but_running_deployments":dead}
json.dump(out, open(f"{bundle}/27_provider_inventory_reconciliation.json","w",encoding="utf-8"), indent=2)
status_rows=list(csv.DictReader(open(f"{bundle}/24_customer_deployments_by_status.csv","r",encoding="utf-8")))
status_counts={r["status"]:int(r["count"]) for r in status_rows}
with open(f"{bundle}/28_reconciliation_counts.md","w",encoding="utf-8") as fh:
    fh.write("# Reconciled Counts vs roadmap note (chatting/may20_post_merge_roadmap_reconciliation.md:327-339)\n\n")
    fh.write("| Metric | Fresh count | Roadmap-note reference |\n| --- | ---: | --- |\n")
    fh.write(f"| Dead-but-running deployments (running EC2 + non-200 health) | {out['counts']['dead_but_running_deployments']} | note claimed 41/43 VMs unhealthy in sample probe |\n")
    fh.write(f"| Inventory rows without non-terminated EC2 match | {out['counts']['inventory_rows_without_nonterminated_ec2_match']} | note claimed ~10 inventory rows mapped to terminated instances |\n")
    fh.write(f"| Deployments stuck in provisioning | {out['counts']['provisioning_deployments']} | note claimed 32 stuck in provisioning |\n\n")
    fh.write("Deployment status distribution from SQL:\n")
    for s,c in sorted(status_counts.items()):
        fh.write(f"- {s}: {c}\n")
