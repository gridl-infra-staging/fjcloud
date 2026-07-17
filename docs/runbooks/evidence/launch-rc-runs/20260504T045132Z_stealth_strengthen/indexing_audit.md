# indexing_audit

## current_dns_exposure

### cloud.flapjack.foo
```bash
$ dig +short @1.1.1.1 cloud.flapjack.foo
104.21.7.70
172.67.187.141

$ dig +short @8.8.8.8 cloud.flapjack.foo
104.21.7.70
172.67.187.141
```

### app.flapjack.foo
```bash
$ dig +short @1.1.1.1 app.flapjack.foo
104.21.7.70
172.67.187.141

$ dig +short @8.8.8.8 app.flapjack.foo
172.67.187.141
104.21.7.70
```

### flapjack.foo
```bash
$ dig +short @1.1.1.1 flapjack.foo
54.211.87.80
52.70.71.107

$ dig +short @8.8.8.8 flapjack.foo
54.211.87.80
52.70.71.107
```

### www.flapjack.foo
```bash
$ dig +short @1.1.1.1 www.flapjack.foo
fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com.
52.70.71.107
54.211.87.80

$ dig +short @8.8.8.8 www.flapjack.foo
fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com.
54.211.87.80
52.70.71.107
```

## historical_index_presence

Latest Common Crawl index discovery command and output used for all hosts:
```bash
$ LATEST_CC_INDEX="$(curl -fsS https://index.commoncrawl.org/collinfo.json | jq -r 'sort_by(.id) | last.id')"
$ printf '%s\n' "$LATEST_CC_INDEX"
CC-MAIN-2026-17
```

### cloud.flapjack.foo
```bash
$ curl -fsS "https://webcache.archive.org/cdx/search/cdx?url=cloud.flapjack.foo/*&output=json&fl=timestamp,original,statuscode,digest"
curl: (6) Could not resolve host: webcache.archive.org

$ curl -fsS "https://index.commoncrawl.org/${LATEST_CC_INDEX}-index?url=cloud.flapjack.foo/*&output=json"
curl: (22) The requested URL returned error: 404
```

### app.flapjack.foo
```bash
$ curl -fsS "https://webcache.archive.org/cdx/search/cdx?url=app.flapjack.foo/*&output=json&fl=timestamp,original,statuscode,digest"
curl: (6) Could not resolve host: webcache.archive.org

$ curl -fsS "https://index.commoncrawl.org/${LATEST_CC_INDEX}-index?url=app.flapjack.foo/*&output=json"
curl: (22) The requested URL returned error: 404
```

### flapjack.foo
```bash
$ curl -fsS "https://webcache.archive.org/cdx/search/cdx?url=flapjack.foo/*&output=json&fl=timestamp,original,statuscode,digest"
curl: (6) Could not resolve host: webcache.archive.org

$ curl -fsS "https://index.commoncrawl.org/${LATEST_CC_INDEX}-index?url=flapjack.foo/*&output=json"
curl: (22) The requested URL returned error: 404
```

### www.flapjack.foo
```bash
$ curl -fsS "https://webcache.archive.org/cdx/search/cdx?url=www.flapjack.foo/*&output=json&fl=timestamp,original,statuscode,digest"
curl: (6) Could not resolve host: webcache.archive.org

$ curl -fsS "https://index.commoncrawl.org/${LATEST_CC_INDEX}-index?url=www.flapjack.foo/*&output=json"
curl: (22) The requested URL returned error: 404
```

Evidence note: `https://flapjack-cloud.pages.dev/` is documented in `ops/runbooks/site_takedown_20260503/STATUS.md` as residual context. It is out of scope for this four-host DNS pass/fail gate; mention retained here because the owner context requires preserving residual-history awareness.

## final_verdict
FAIL: DNS exposure gate failed at capture time because all four audited hosts returned non-empty results from both public resolvers (`@1.1.1.1` and `@8.8.8.8`).

Historical archive/index summary: capture commands were run for each host exactly as specified. Wayback command host `webcache.archive.org` failed DNS resolution (`curl: (6)`), and latest Common Crawl index query (`CC-MAIN-2026-17`) returned HTTP 404 for each host. These are recorded as probe outcomes only and do not negate the DNS-fail condition.
