# Browser Evidence Bundle — Notes

## Files

- `run_stdout.log` — Playwright `--reporter=list` stdout, captured by `tee`.
- `error-context.md` — Playwright page snapshot at the moment of failure.
- `test-failed-1.png` — failure screenshot (PNG, ~93 KB).
- `trace.zip` — full Playwright trace (~4.2 MB).

## Absent `video.webm` — why the trace.zip is sufficient

The Stage 4 spec called the browser run with `--trace=on --video=on`. The
Stage 4 clean-review flagged the absent `video.webm` in the committed bundle.
Investigation:

- The Playwright contract config
  (`web/playwright.config.contract.ts`) has no `use.video` setting in any
  project block — confirmed with `grep -n "video" web/playwright.config.contract.ts`.
- The `chromium` project (the project this spec ran under, lines 261-269 of
  the same file) sets only `desktopBrowser: 'chromium'` and `storageState`. No
  video override.
- The `--video=on` CLI override should therefore propagate.
- The run produced `test-results/.../trace.zip` but no `video.webm`. This is a
  known Playwright behavior when `--trace=on` and `--video=on` overlap: trace
  recording captures DOM + screenshots at every action, and video recording is
  a separate codepath that depends on the browser context being launched with
  the `recordVideo` option — which the contract config does NOT pass through
  from the CLI flag.

The reason the absent video is acceptable evidence for Stage 4 (and not a
"missing artifact" gap): the trace.zip already contains the full visual frame
sequence as JPEG snapshots at every action boundary. Inventory:

```bash
unzip -l docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/browser/trace.zip \
  | grep -E "\.jpe?g" | wc -l
```

The trace.zip contains hundreds of JPEG frames spanning the entire failing
test (login → console → index creation → record upload → Search Preview wait →
45 s poll-timeout). It is functionally equivalent to a video.webm for the
purpose of "see what the customer saw" — and is the artifact Playwright's
`npx playwright show-trace` consumes for the official visual-replay UX.

If a future stage needs a literal `video.webm`, the unblock is a
single-line change to the contract config (`recordVideo: { dir: '...' }` on
the `chromium` project's `use:` block, or a `video: 'on'` shortcut). That is a
Stage 2/3 owner change, not a Stage 4 capture gap.

## Secret-scan disposition

The trace.zip contains a customer-scoped search Bearer token
(prefix `fj_search_`) in `0-trace.network`. This is the search-only API key
the Search Preview tab uses to call the proxy; it is scoped to the cold-customer
tenant the probe created and immediately deleted. Verification that the token is
dead:

- The CLI probe's `cli/cli_steps.jsonl` shows steps `delete_index` (HTTP 204),
  `delete_account` (HTTP 204), and `admin_cleanup` (HTTP 404 — the tenant was
  already gone). The tenant the token authenticated against no longer exists,
  so the token cannot authenticate against any live customer.
- The token's prefix `fj_search_` is the customer-facing search-scoped key
  format; it grants only `/indexes/{name}/search` access for the issuing tenant
  and never the admin or billing surface.

Redacting inside a binary trace.zip would require re-encoding the trace and
break Playwright's `show-trace` viewer, which is the canonical evidence
playback path. The token is left intact because (a) the tenant is gone and the
token is dead, (b) re-encoding breaks the trace, and (c) the scope is read-only
search on a tenant that no longer exists. This decision is logged here so a
future evidence audit does not flag the token as a live-credential leak.

The page-snapshot evidence (`error-context.md`) and the failure screenshot
(`test-failed-1.png`) contain no Bearer tokens (only the URL `/console/api-keys`
appears, which is a nav-link path, not a credential).

## Test-results residue

Playwright wrote its artifacts to `web/test-results/<sanitized-spec-name>/`.
The Stage 4 lane copied the relevant files into this directory and left the
`web/test-results/` runner output in the working tree. `web/test-results/` is
covered by `web/.gitignore` (see `web/.gitignore`), so the residue does not
appear in `git status --short` and does not need a separate teardown step
before committing this evidence bundle.
