// Dashboard pages own form actions (settings, billing, indexes, api-keys,
// migrate, etc.) and read per-request session state via the dashboard
// layout-server, so they cannot be prerendered. Opt the entire dashboard
// subtree out of prerendering to override the public root layout.
export const prerender = false;
