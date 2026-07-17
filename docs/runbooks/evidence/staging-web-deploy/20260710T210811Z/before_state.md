# Stage 1 Before-State Summary

Source: `session_handoffs/stage_01/before_state_20260710T201543Z.md`.

Stage 1 confirmed the stale staging surface before any deploy mutation:

- `cloud.staging.flapjack.foo/_app/version.json` served `1783556911547`.
- `staging.flapjack-cloud.pages.dev/_app/version.json` also served `1783556911547`.
- `cloud.flapjack.foo/_app/version.json` served `1783701529567`.
- `flapjack-cloud.pages.dev/_app/version.json` also served `1783701529567`.
- `cloud.staging.flapjack.foo/pricing` returned zero matches for `Get Started Free`.
- `cloud.flapjack.foo/pricing` returned at least one `Get Started Free` match.

Cloudflare DNS API readback confirmed the topology:

| Host | CNAME target | Proxied |
| --- | --- | --- |
| `cloud.staging.flapjack.foo` | `staging.flapjack-cloud.pages.dev` | `true` |
| `cloud.flapjack.foo` | `flapjack-cloud.pages.dev` | `true` |

The Pages deployment scan found the newest `branch=staging` deployment was `09bdac9a`,
created `2026-07-09T00:29:04Z`, while newer `branch=main` deployments existed. The
observed root cause was therefore the stale Cloudflare Pages `staging` branch alias, not
a stuck custom-domain attachment.
