// Admin pages are dynamic and own form actions (login, fleet ops, billing
// migrations, etc.). Forcing prerender=true at the root layout cascades into
// these routes and fails them with `Cannot prerender pages with actions`,
// so explicitly opt the entire admin subtree out of prerendering.
export const prerender = false;
