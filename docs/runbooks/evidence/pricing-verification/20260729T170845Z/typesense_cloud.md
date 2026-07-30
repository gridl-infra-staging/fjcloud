# Typesense Cloud Pricing Verification

UTC timestamp: 2026-07-29T17:08:45Z

Declared URL read: https://cloud.typesense.org/pricing

Fetch/probe command:

```bash
mkdir -p /tmp/fjcloud_stage2_pricing_probe
curl -sS -L --max-time 45 --connect-timeout 15 -A 'fjcloud-pricing-verification/1.0' -w '%{http_code} %{url_effective} %{time_total}' -o /tmp/fjcloud_stage2_pricing_probe/page_1.html 'https://cloud.typesense.org/pricing'
```

Effective URL after redirects: https://cloud.typesense.org/pricing/calculator

HTTP status: 200

Evidence extraction command:

```bash
python3 scripts/extract_pricing_evidence_text.py /tmp/fjcloud_stage2_pricing_probe/page_1.html /tmp/fjcloud_stage2_pricing_probe/page_1.txt
rg -n --ignore-case '1 GiB|1GB|1 GB|2 GiB|2GB|2 GB|4 GiB|4GB|4 GB|8 GiB|8GB|8 GB|16 GiB|16GB|16 GB|32 GiB|32GB|32 GB|64 GiB|64GB|64 GB|0\.054|\$0\.054|\$0\.10|\$0\.19|\$0\.38|\$0\.74|\$1\.39|\$2\.46|High Availability' /tmp/fjcloud_stage2_pricing_probe/page_1.txt
```

## Verdict

Overall: unverified. Keep `metadata().last_verified = None` because the fetched public page confirms the modeled RAM choices and 3-node HA selector but does not expose the modeled hourly tier prices.

| constant | repo value | source value | verdict | evidence note |
| --- | ---: | ---: | --- | --- |
| `RAM_TIERS[0].ram_gib` | 1 GiB | 1 GB option | match | Text extraction lines 19-25 list memory options including 1 GB through 64 GB. |
| `RAM_TIERS[0].hourly_cents` | 5.4 cents/hour | not found | not-found-at-source | Fetched page did not include `$0.054` or equivalent single-node hourly price. |
| `RAM_TIERS[1].ram_gib` | 2 GiB | 2 GB option | match | Text extraction lines 19-25 list memory options including 2 GB. |
| `RAM_TIERS[1].hourly_cents` | 10 cents/hour | not found | not-found-at-source | Fetched page did not include `$0.10` or equivalent single-node hourly price. |
| `RAM_TIERS[2].ram_gib` | 4 GiB | 4 GB option | match | Text extraction lines 19-25 list memory options including 4 GB. |
| `RAM_TIERS[2].hourly_cents` | 19 cents/hour | not found | not-found-at-source | Fetched page did not include `$0.19` or equivalent single-node hourly price. |
| `RAM_TIERS[3].ram_gib` | 8 GiB | 8 GB option | match | Text extraction lines 19-25 list memory options including 8 GB. |
| `RAM_TIERS[3].hourly_cents` | 38 cents/hour | not found | not-found-at-source | Fetched page did not include `$0.38` or equivalent single-node hourly price. |
| `RAM_TIERS[4].ram_gib` | 16 GiB | 16 GB option | match | Text extraction lines 19-25 list memory options including 16 GB. |
| `RAM_TIERS[4].hourly_cents` | 74 cents/hour | not found | not-found-at-source | Fetched page did not include `$0.74` or equivalent single-node hourly price. |
| `RAM_TIERS[5].ram_gib` | 32 GiB | 32 GB option | match | Text extraction lines 19-25 list memory options including 32 GB. |
| `RAM_TIERS[5].hourly_cents` | 139 cents/hour | not found | not-found-at-source | Fetched page did not include `$1.39` or equivalent single-node hourly price. |
| `RAM_TIERS[6].ram_gib` | 64 GiB | 64 GB option | match | Text extraction lines 19-25 list memory options including 64 GB. |
| `RAM_TIERS[6].hourly_cents` | 246 cents/hour | not found | not-found-at-source | Fetched page did not include `$2.46` or equivalent single-node hourly price. |
| `HA_NODE_COUNT` | 3 | 3-node selector option | match | Text extraction lines 42-45 show High Availability, Number of nodes, and option 3. |
