# FR-6F staging deploy receipt

- Bundle UTC: `2026-08-07T16:42:41Z`
- Source target SHA: `694daac94d8bdf8fbdaacc2497676667166c0d98`
- Source condition: detached, clean, and pinned to the fetched `origin/main`
- Preflight staging dev SHA: `8e4c4e52e799539d7f79bca60dcb38ef532cf35f`
- Preflight deployable drift: `true`
- Preflight doc-only ahead: `false`
- Debbie command: `debbie sync staging`
- Debbie start: `2026-08-07T16:47:00Z`
- Debbie end: `2026-08-07T16:56:20Z`
- Debbie exit: `0`
- Post-sync staging manifest dev SHA: `694daac94d8bdf8fbdaacc2497676667166c0d98`
- Post-sync manifest matches dev: `true`
- Post-sync staging checkout clean: `true`
- Post-sync staging HEAD matches origin: `true`
- New mirror run ID: `31199924808`
- Mirror head: `06ba4b38edb6b891aaa918ae964c1d42dcb5f9fe`
- Run head SHA: `06ba4b38edb6b891aaa918ae964c1d42dcb5f9fe`
- Mirror conclusion: `failure`
- Mirror probe reason: `ci_non_success`
- Poll elapsed: `240` seconds
- Producer outcome: **failed attempt recorded**. The detached-source staging sync succeeded and its manifest is target-bound, but the required staging-mirror CI acceptance did not succeed.
- Retry disposition: no second Debbie sync and no further poll were attempted after the terminal CI failure.

Raw command output and machine-readable state are preserved in `command_outputs/`.
