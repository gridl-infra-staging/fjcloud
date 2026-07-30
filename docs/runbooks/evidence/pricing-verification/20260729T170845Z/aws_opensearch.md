# AWS OpenSearch Service Pricing Verification

UTC timestamp: 2026-07-29T17:08:45Z

Declared URL read: https://aws.amazon.com/opensearch-service/pricing/

Fetch/probe command:

```bash
mkdir -p /tmp/fjcloud_stage2_pricing_probe
curl -sS -L --max-time 45 --connect-timeout 15 -A 'fjcloud-pricing-verification/1.0' -w '%{http_code} %{url_effective} %{time_total}' -o /tmp/fjcloud_stage2_pricing_probe/page_3.html 'https://aws.amazon.com/opensearch-service/pricing/'
```

Effective URL after redirects: https://aws.amazon.com/opensearch-service/pricing/

HTTP status: 200

Evidence extraction command:

```bash
python3 scripts/extract_pricing_evidence_text.py /tmp/fjcloud_stage2_pricing_probe/page_3.html /tmp/fjcloud_stage2_pricing_probe/page_3.txt
rg -n --ignore-case 't3\.small\.search|t3\.medium\.search|m6g\.large\.search|r6g\.large\.search|r6g\.xlarge\.search|r6g\.2xlarge\.search|r6g\.4xlarge\.search|gp3|0\.036|0\.073|0\.128|0\.167|0\.335|0\.669|1\.339|0\.122|0\.09|data transfer|dedicated master|three dedicated' /tmp/fjcloud_stage2_pricing_probe/page_3.html /tmp/fjcloud_stage2_pricing_probe/page_3.txt
```

## Verdict

Overall: unverified. Keep `metadata().last_verified = None` because the fetched public page confirms gp3 example pricing and one modeled instance rate but does not source-back every modeled instance type, the `m6g.large.search` dedicated master choice, or the exact modeled outbound transfer cents value.

| constant | repo value | source value | verdict | evidence note |
| --- | ---: | ---: | --- | --- |
| `INSTANCE_TYPES[0]` | `t3.small.search`, 2 vCPU, 2 GiB, 3.6 cents/hour | not found | not-found-at-source | Fetched page did not expose this modeled instance row or $0.036/hour rate. |
| `INSTANCE_TYPES[1]` | `t3.medium.search`, 2 vCPU, 4 GiB, 7.3 cents/hour | not found | not-found-at-source | Fetched page did not expose this modeled instance row or $0.073/hour rate. |
| `INSTANCE_TYPES[2]` | `m6g.large.search`, 2 vCPU, 8 GiB, 12.8 cents/hour | not found | not-found-at-source | Fetched page did not expose this modeled instance row or $0.128/hour rate. |
| `INSTANCE_TYPES[3]` | `r6g.large.search`, 2 vCPU, 16 GiB, 16.7 cents/hour | not found | not-found-at-source | Fetched page did not expose this modeled instance row or $0.167/hour rate. |
| `INSTANCE_TYPES[4]` | `r6g.xlarge.search`, 4 vCPU, 32 GiB, 33.5 cents/hour | `r6g.xlarge.search = $0.335 per hour` | match | HTML line 1358 includes the modeled rate in a pricing example. |
| `INSTANCE_TYPES[5]` | `r6g.2xlarge.search`, 8 vCPU, 64 GiB, 66.9 cents/hour | not found | not-found-at-source | Fetched page did not expose this modeled instance row or $0.669/hour rate. |
| `INSTANCE_TYPES[6]` | `r6g.4xlarge.search`, 16 vCPU, 128 GiB, 133.9 cents/hour | not found | not-found-at-source | Fetched page did not expose this modeled instance row or $1.339/hour rate. |
| `EBS_GP3_CENTS_PER_GIB_MONTH` | 12.2 cents/GiB-month | `$0.122 per GB / month` | match | Text extraction lines 502 and 550 show gp3 storage at $0.122 per GB/month. |
| `DATA_TRANSFER_CENTS_PER_GB` | 9 cents/GB | standard AWS data transfer charges | not-found-at-source | Text extraction lines 244-247 delegate to standard AWS data transfer charges but do not give the modeled $0.09/GB value on the declared OpenSearch page. |
| `DEDICATED_MASTER_NODE_COUNT` | 3 | three cluster manager nodes in examples | match | Text extraction lines 403 and 413-415 include three cluster manager nodes in a production example. |
| `DEDICATED_MASTER_INSTANCE_NAME` | `m6g.large.search` | `c6g.large.search` and `r8g.large.search` examples | mismatch | Text extraction lines 403 and 413 show `c6g.large.search`; line 534 shows `r8g.large.search`, not the modeled `m6g.large.search`. No constant change made because the page examples do not state a general replacement assumption for this model. |
