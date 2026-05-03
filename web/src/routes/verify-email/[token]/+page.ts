// Email verification consumes a one-time [token] from the API and cannot be
// prerendered — the load function calls `api.verifyEmail({ token })` which
// invalidates the token on the API side, so static-baked HTML would either
// burn the token at build time or render against a stale state.
//
// Without this opt-out, the root +layout.ts `prerender = true` cascades and
// adapter-cloudflare strips this route from the runtime Worker manifest,
// producing 404 for every /verify-email/<token> request — the exact symptom
// LB-2 Phase B exposed after the adapter-cloudflare migration.
export const prerender = false;
