<script lang="ts">
	import '../app.css';
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
	import favicon from '$lib/assets/favicon.ico';
	import { SUPPORT_EMAIL } from '$lib/format';
	import BetaSupportBadge from '$lib/components/BetaSupportBadge.svelte';
	import { onMount } from 'svelte';
	import {
		installBrowserRuntimeFailureListeners,
		reportBrowserRuntimeFailure
	} from '$lib/error-boundary/client-runtime';

	let { children } = $props();

	const PUBLIC_TRUST_PATHS = new Set(['/', '/pricing', '/terms', '/privacy', '/dpa']);
	const LEGAL_PAGE_PATHS = new Set(['/terms', '/privacy', '/dpa']);
	// Pages that should render with the colorful diner-style teal/cream palette
	// instead of the plain white default. Legal pages and the landing page itself
	// share the palette so the logged-out marketing surface stays brand-consistent.
	// See bugs/2026_05_22_landing_page_color_scheme_regression.md.
	const COLORFUL_SHELL_PATHS = new Set(['/', '/terms', '/privacy', '/dpa']);

	function normalizedPathname(pathname: string): string {
		if (pathname === '/') {
			return pathname;
		}
		return pathname.endsWith('/') ? pathname.slice(0, -1) : pathname;
	}

	const pathname = $derived(normalizedPathname(page.url.pathname));
	const showPublicTrustChrome = $derived(PUBLIC_TRUST_PATHS.has(pathname));
	const showLegalPageWrapper = $derived(LEGAL_PAGE_PATHS.has(pathname));
	const useColorfulShell = $derived(COLORFUL_SHELL_PATHS.has(pathname));
	const publicTrustShellClass = $derived(
		useColorfulShell
			? 'min-h-screen bg-flapjack-mint text-flapjack-ink'
			: 'min-h-screen bg-white text-flapjack-ink'
	);

	onMount(() => installBrowserRuntimeFailureListeners(reportBrowserRuntimeFailure));
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

{#if showPublicTrustChrome}
	<div class={publicTrustShellClass}>
		<header class="border-b border-flapjack-ink/20">
			<div
				class="mx-auto flex max-w-6xl flex-col gap-3 px-6 py-3 sm:h-16 sm:flex-row sm:items-center sm:justify-between sm:gap-6 sm:py-0"
			>
				<div class="flex items-center justify-between gap-3">
					<a
						href={resolve('/')}
						class="text-xl font-bold font-['Cabinet'] text-flapjack-ink sm:text-2xl"
					>
						Flapjack Cloud
					</a>
					<span
						class="rounded border border-flapjack-ink/40 px-2 py-0.5 text-xs font-bold tracking-widest text-flapjack-ink/70"
					>
						BETA
					</span>
				</div>
				<nav class="grid grid-cols-[2.25rem_1fr] items-center gap-3 sm:flex sm:w-auto">
					<a
						href="https://github.com/griddlehq/flapjack"
						class="inline-flex h-9 w-9 items-center justify-center border border-flapjack-ink/30 hover:bg-flapjack-cream/80"
						aria-label="GitHub repository"
						target="_blank"
						rel="noreferrer"
					>
						<svg
							viewBox="0 0 16 16"
							aria-hidden="true"
							focusable="false"
							class="h-4 w-4 fill-current"
						>
							<path
								d="M8 0C3.58 0 0 3.67 0 8.19c0 3.62 2.29 6.69 5.47 7.78.4.08.55-.18.55-.4v-1.52c-2.23.5-2.69-.97-2.69-.97-.36-.95-.89-1.2-.89-1.2-.73-.51.05-.5.05-.5.81.06 1.24.85 1.24.85.71 1.26 1.87.9 2.33.69.07-.53.28-.9.51-1.1-1.78-.21-3.64-.91-3.64-4.03 0-.89.31-1.62.82-2.19-.08-.21-.36-1.04.08-2.16 0 0 .68-.22 2.2.84A7.45 7.45 0 0 1 8 4c.68 0 1.36.09 1.99.28 1.53-1.06 2.2-.84 2.2-.84.44 1.12.16 1.95.08 2.16.51.57.82 1.3.82 2.19 0 3.13-1.87 3.82-3.65 4.02.29.26.55.76.55 1.54v2.22c0 .22.15.48.55.4A8.14 8.14 0 0 0 16 8.19C16 3.67 12.42 0 8 0Z"
							/>
						</svg>
					</a>
					<a
						href={resolve('/login')}
						class="inline-flex h-9 items-center justify-center whitespace-nowrap text-sm font-medium text-flapjack-ink/70 hover:text-flapjack-ink"
					>
						Log In
					</a>
					<!-- Public Sign Up CTA removed during invite-only beta. See docs/decisions/2026_05_23_beta_signup_gate.md -->
				</nav>
			</div>
		</header>

		<div class="border-b border-flapjack-ink/20 bg-flapjack-cream" data-testid="public-beta-banner">
			<div
				class="mx-auto flex max-w-6xl flex-col gap-2 px-6 py-3 text-sm text-flapjack-ink/80 sm:flex-row sm:items-center sm:justify-between"
			>
				<BetaSupportBadge betaLinkLabel="Learn about the beta" compact={false} />
			</div>
		</div>

		{#if showLegalPageWrapper}
			<main class="mx-auto max-w-4xl px-6 py-12" data-testid="public-legal-shell">
				<a
					href={resolve('/')}
					class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
				>
					Back to Flapjack Cloud
				</a>
				{@render children()}
			</main>
		{:else}
			{@render children()}
		{/if}

		<footer class="border-t border-flapjack-ink/20 py-8">
			<div
				class="mx-auto flex max-w-6xl flex-col justify-between gap-4 px-6 text-sm text-flapjack-ink/60 sm:flex-row"
			>
				<p>&copy; {new Date().getFullYear()} Flapjack Cloud. Contact: {SUPPORT_EMAIL}</p>
				<nav class="flex flex-wrap gap-4" aria-label="Legal">
					<a href={resolve('/terms')} class="text-flapjack-rose hover:text-flapjack-plum">Terms</a>
					<a href={resolve('/privacy')} class="text-flapjack-rose hover:text-flapjack-plum"
						>Privacy</a
					>
					<a href={resolve('/dpa')} class="text-flapjack-rose hover:text-flapjack-plum">DPA</a>
					<a href={resolve('/status')} class="text-flapjack-rose hover:text-flapjack-plum">Status</a
					>
				</nav>
			</div>
		</footer>
	</div>
{:else}
	{@render children()}
{/if}
