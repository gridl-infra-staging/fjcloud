// Static builds only prerender the public entries listed in svelte.config.js.
// The canonical staging hostname is reconciled by the infra/runtime contract,
// so this file should not be read as the owner of staging DNS routing policy.
//
// Dynamic subtrees (admin, signup, logout, dashboard, etc.) opt out via
// `export const prerender = false;` in their own `+layout.ts` / `+page.ts`,
// because pages with form `actions` cannot be prerendered.
export const prerender = true;
