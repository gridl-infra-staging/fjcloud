// /status must remain dynamic so SERVICE_STATUS(_UPDATED) is read at request time
// from Cloudflare runtime env vars instead of being baked at build time.
export const prerender = false;
