# Stage 2 Evidence Notes

- Bundle reused from `.stage1_bundle_path`: `docs/runbooks/evidence/public-release-verify/20260709T070915Z`.
- Production GET-only proof passed: `pricing_cloud.html` contains a signup path, `signup_cloud.code` is 200, and the canonical signup SSR probe found `Create your account`, `name="confirm_password"`, and `<form method="POST">`.
- Staging signup SSR proof passed: `signup_cloud_staging.code` is 200 and the canonical signup SSR probe found all required markers.
- Staging pricing CTA proof failed after one bounded retry: `pricing_cloud_staging.html` and `pricing_cloud_staging_retry.html` do not contain a signup path.
- Pages parity passed for both aliases against expected SHA `d6cc42182bcd8c0f32335b8520e5a576e36cc1dd`; see `pages_parity.log`.
- Deployed public-pages Playwright proof ran on staging only, by design. Production stayed GET-only because submitting prod signup would create a live customer and Stripe object; submit-path coverage is delegated to the shared Pages deployment plus the staging browser proof.
- Staging Playwright proof failed after bounded rerun with 3 missing-signup-CTA failures and 9 passing rows; see `stage2_public_pages_playwright.log` and `stage2_public_pages_playwright_rerun.log`.
- Required fix-lane stubs authored: `chats/icg/stubs/jul06_pm_5_public_signup_surface_deploy_defect.md` and `chats/icg/stubs/jul06_pm_5_pages_or_public_browser_deploy_defect.md`.
