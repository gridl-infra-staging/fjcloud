// /logout owns a POST form action and has no +page.svelte; opt out of
// prerender so SvelteKit doesn't attempt to render it during static
// builds (`Cannot prerender pages with actions`). GET requests will
// surface the natural 405/missing-component response from SvelteKit
// rather than a 500 from the prerender path validator.
export const prerender = false;
