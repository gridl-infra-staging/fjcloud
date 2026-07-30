# Elastic Cloud Pricing Verification

UTC timestamp: 2026-07-29T17:08:45Z

Declared URL read: https://www.elastic.co/pricing/cloud-hosted

Fetch/probe command:

```bash
mkdir -p /tmp/fjcloud_stage2_pricing_probe
curl -sS -L --max-time 45 --connect-timeout 15 -A 'fjcloud-pricing-verification/1.0' -w '%{http_code} %{url_effective} %{time_total}' -o /tmp/fjcloud_stage2_pricing_probe/page_2.html 'https://www.elastic.co/pricing/cloud-hosted'
```

Effective URL after redirects: https://www.elastic.co/pricing/cloud-hosted

HTTP status: 200

Evidence extraction command:

```bash
python3 scripts/extract_pricing_evidence_text.py /tmp/fjcloud_stage2_pricing_probe/page_2.html /tmp/fjcloud_stage2_pricing_probe/page_2.txt
rg -n --ignore-case '\$99|99/month|120 GB|2 availability|availability zones|4 GB|8 GB|16 GB|32 GB|64 GB|198|396|792|1584|standard' /tmp/fjcloud_stage2_pricing_probe/page_2.txt
```

## Verdict

Overall: unverified. Keep `metadata().last_verified = None` because the fetched public page confirms only the Standard baseline price and production-config storage/zone footnote, not the scaled modeled tier table.

| constant | repo value | source value | verdict | evidence note |
| --- | ---: | ---: | --- | --- |
| `INSTANCE_TIERS[0].ram_gib` | 4 GiB | not found | not-found-at-source | Fetched page did not expose the modeled 4 GiB RAM tier. |
| `INSTANCE_TIERS[0].storage_gib` | 120 GiB | 120 GB storage | match | Text extraction line 302 says the cloud production config is based on 120 GB storage / 2 zones. |
| `INSTANCE_TIERS[0].monthly_cents` | 9,900 cents/month | $99 per month | match | Text extraction lines 166-168 show Standard as low as $99 per month. |
| `INSTANCE_TIERS[1].ram_gib` | 8 GiB | not found | not-found-at-source | Fetched page did not expose the modeled 8 GiB RAM tier. |
| `INSTANCE_TIERS[1].storage_gib` | 240 GiB | not found | not-found-at-source | Fetched page did not expose the modeled scaled 240 GiB storage tier. |
| `INSTANCE_TIERS[1].monthly_cents` | 19,800 cents/month | not found | not-found-at-source | Fetched page did not expose the modeled $198/month scaled tier. |
| `INSTANCE_TIERS[2].ram_gib` | 16 GiB | not found | not-found-at-source | Fetched page did not expose the modeled 16 GiB RAM tier. |
| `INSTANCE_TIERS[2].storage_gib` | 480 GiB | not found | not-found-at-source | Fetched page did not expose the modeled scaled 480 GiB storage tier. |
| `INSTANCE_TIERS[2].monthly_cents` | 39,600 cents/month | not found | not-found-at-source | Fetched page did not expose the modeled $396/month scaled tier. |
| `INSTANCE_TIERS[3].ram_gib` | 32 GiB | not found | not-found-at-source | Fetched page did not expose the modeled 32 GiB RAM tier. |
| `INSTANCE_TIERS[3].storage_gib` | 960 GiB | not found | not-found-at-source | Fetched page did not expose the modeled scaled 960 GiB storage tier. |
| `INSTANCE_TIERS[3].monthly_cents` | 79,200 cents/month | not found | not-found-at-source | Fetched page did not expose the modeled $792/month scaled tier. |
| `INSTANCE_TIERS[4].ram_gib` | 64 GiB | not found | not-found-at-source | Fetched page did not expose the modeled 64 GiB RAM tier. |
| `INSTANCE_TIERS[4].storage_gib` | 1,920 GiB | not found | not-found-at-source | Fetched page did not expose the modeled scaled 1,920 GiB storage tier. |
| `INSTANCE_TIERS[4].monthly_cents` | 158,400 cents/month | not found | not-found-at-source | Fetched page did not expose the modeled $1,584/month scaled tier. |
