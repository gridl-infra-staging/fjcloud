# Stage 1 Deploy-Currency and Pages Parity Summary

- Evidence bundle: `docs/runbooks/evidence/polished-beta-staging-verify/20260713T002451Z_jul12_stage1_preflight`
- Live-state summary: `docs/live-state/20260713T002522Z/SUMMARY.md`
- Target dev SHA (`origin/main`): `81a1c486f7b52638af445b34fcf9e22f8c857cfa`
- Local HEAD SHA: `dc2146379d461cbe23d39966a588747d6778e04f`
- Staging API dev SHA: `81a1c486f7b52638af445b34fcf9e22f8c857cfa`
- Staging mirror SHA / Pages target: `a787e504ef65415543856887327ed7ba13fd08d0`
- Deployable drift: `false`
- Debbie sync staging: `not_needed`
- Pages parity ready: `true`
- Pages served version SHA: `a787e504ef65415543856887327ed7ba13fd08d0`
- Pricing control sample: `pass`

## Verdict

Stage 1 deploy-currency preflight is green. Staging API `/version.dev_sha` matches the merged dev `origin/main` SHA, deployable drift is false, Cloudflare Pages served bytes match the staging mirror SHA, and the known-green pricing control sample returned the canonical pricing tax disclaimer.
