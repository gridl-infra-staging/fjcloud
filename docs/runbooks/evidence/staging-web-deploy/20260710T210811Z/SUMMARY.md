# Staging Web Deploy Evidence Summary

This bundle records the branch-aware staging web deploy diagnosis and fix chain.

Stage 1 proved that `cloud.staging.flapjack.foo` served the stale Cloudflare Pages
`staging` branch alias (`staging.flapjack-cloud.pages.dev`), while production served a
newer `main` deployment. The custom-domain-mapping theory was falsified: the DNS target
was correct, but the `staging` branch had not received a current Pages deploy.

Stage 2 proved the remediation shape by manually deploying to `--branch=staging`; the
served staging marker changed to `1783715879386` and the `Get Started Free` CTA appeared.

Stage 3 authored the CI fix: `deploy-staging` now publishes the built web artifact to
both the existing `--branch=main` target and the `--branch=staging` branch alias, with
contract coverage and corrected topology docs.

`ROADMAP.md` remains the canonical owner of deferred follow-up status, including the
two-token prod-mirror split. The W1 post-merge gate remains the canonical owner of the
final served-surface closeout after the next staging CI cycle deploys to the Pages
`staging` branch and the served-surface probe passes.
