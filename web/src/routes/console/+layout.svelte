<script lang="ts">
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { DASHBOARD_SESSION_EXPIRED_REDIRECT } from '$lib/auth-session-contracts';
	import { resolve } from '$app/paths';
	import { planLabel, SUPPORT_EMAIL } from '$lib/format';
	import BetaSupportBadge from '$lib/components/BetaSupportBadge.svelte';
	import { CANONICAL_PUBLIC_API_DOCS_URL } from '$lib/public_api';
	import { parseRetryAfterSeconds, retryAfterSecondsFromHeaders } from '$lib/http/retry_after';

	let { data, children } = $props();

	const planContext = $derived(data.planContext);
	const profile = $derived(data.profile);
	const displayName = $derived(profile?.name || data.user?.customerId || '');
	const onBillingRoute = $derived(page.url.pathname.startsWith('/console/billing'));

	const navItems = [
		{ href: '/console' as const, label: 'Console', icon: 'home' },
		{ href: '/console/indexes' as const, label: 'Indexes', icon: 'database' },
		{ href: '/console/billing' as const, label: 'Billing', icon: 'credit-card' },
		{ href: '/console/api-keys' as const, label: 'API Keys', icon: 'key' },
		{ href: '/console/logs' as const, label: 'Logs', icon: 'list' },
		{ href: '/console/account' as const, label: 'Account', icon: 'settings' }
	];
	const supportMailtoHref = `mailto:${SUPPORT_EMAIL}`;
	const helpItems = [
		{ href: supportMailtoHref, label: 'Support', external: false },
		{ href: CANONICAL_PUBLIC_API_DOCS_URL, label: 'API Docs', external: true }
	];

	function isActive(href: string): boolean {
		if (href === '/console/account') {
			return (
				page.url.pathname.startsWith('/console/account') ||
				page.url.pathname.startsWith('/console/settings')
			);
		}
		if (href === '/console') return page.url.pathname === '/console';
		return page.url.pathname.startsWith(href);
	}

	function hasSessionExpiredFormMarker(form: unknown): form is { _authSessionExpired: true } {
		if (typeof form !== 'object' || form === null) return false;
		return (form as Record<string, unknown>)._authSessionExpired === true;
	}

	let mobileNavOpen = $state(false);

	function closeMobileNav() {
		mobileNavOpen = false;
	}

	function toggleMobileNav() {
		mobileNavOpen = !mobileNavOpen;
	}

	function closeMobileNavAfterNavigation() {
		mobileNavOpen = false;
	}

	let redirectedForSessionExpiry = $state(false);
	$effect(() => {
		if (redirectedForSessionExpiry) return;
		if (!hasSessionExpiredFormMarker(page.form)) return;
		redirectedForSessionExpiry = true;
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- DASHBOARD_SESSION_EXPIRED_REDIRECT carries a query string (`?reason=...`) that resolve() rejects as a typed route literal; the path itself is statically owned by $lib/auth-session-contracts.
		void goto(DASHBOARD_SESSION_EXPIRED_REDIRECT);
	});

	const showVerificationBanner = $derived(profile?.email_verified === false);
	let resendInFlight = $state(false);
	let resendResultKind = $state<'success' | 'error' | null>(null);
	let resendResultMessage = $state('');
	let resendCooldownSeconds = $state<number | null>(null);

	async function resendVerificationFromShell() {
		if (resendInFlight) return;
		resendInFlight = true;

		try {
			const response = await fetch(resolve('/console/resend-verification'), {
				method: 'POST'
			});
			const retryAfterSeconds = retryAfterSecondsFromHeaders(response.headers);
			let payload: Record<string, unknown> = {};
			try {
				payload = (await response.json()) as Record<string, unknown>;
			} catch {
				payload = {};
			}

			if (
				(response.status === 401 || response.status === 403) &&
				payload._authSessionExpired === true
			) {
				redirectedForSessionExpiry = true;
				// eslint-disable-next-line svelte/no-navigation-without-resolve -- DASHBOARD_SESSION_EXPIRED_REDIRECT carries a query string (`?reason=...`) that resolve() rejects as a typed route literal; the path itself is statically owned by $lib/auth-session-contracts.
				void goto(DASHBOARD_SESSION_EXPIRED_REDIRECT);
				return;
			}

			const payloadRetryAfter = parseRetryAfterSeconds(payload.retryAfterSeconds);
			resendCooldownSeconds = payloadRetryAfter ?? retryAfterSeconds;

			if (response.ok) {
				resendResultKind = 'success';
				resendResultMessage =
					typeof payload.message === 'string' && payload.message.trim().length > 0
						? payload.message
						: 'Verification email sent';
				return;
			}

			resendResultKind = 'error';
			resendResultMessage =
				typeof payload.error === 'string' && payload.error.trim().length > 0
					? payload.error
					: 'Failed to resend verification email';
		} catch {
			resendCooldownSeconds = null;
			resendResultKind = 'error';
			resendResultMessage = 'Failed to resend verification email';
		} finally {
			resendInFlight = false;
		}
	}
</script>

{#snippet renderShellNavigation(isMobile: boolean)}
	<!-- P.brand_palette_consistency, M.universal.1: dashboard nav active/inactive color states cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__mobile_narrow.json -->
	<nav class="space-y-1">
		{#each navItems as item (item.href)}
			<a
				href={resolve(item.href)}
				class="flex items-center rounded-lg px-3 py-2 text-sm font-medium transition-colors {isActive(
					item.href
				)
					? isMobile
						? 'bg-flapjack-mint/20 text-flapjack-ink'
						: 'bg-flapjack-mint text-flapjack-ink'
					: 'text-flapjack-ink hover:bg-flapjack-mint/20 hover:text-flapjack-ink'}"
				onclick={isMobile ? closeMobileNavAfterNavigation : undefined}
			>
				{item.label}
			</a>
		{/each}
	</nav>
	<!-- P.brand_palette_consistency, M.universal.1: help section border/label/link tones cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__loading__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json -->
	<div class="mt-6 border-t pt-4 border-flapjack-ink/20">
		<p class="mb-2 text-xs font-semibold uppercase tracking-wide text-flapjack-ink/60">Help</p>
		<div class="space-y-1">
			{#each helpItems as item (item.href)}
				<!-- eslint-disable svelte/no-navigation-without-resolve -- support mailto and canonical docs URL are external destinations -->
				<a
					href={item.href}
					target={item.external ? '_blank' : undefined}
					rel={item.external ? 'noreferrer' : undefined}
					class="flex items-center rounded-lg px-3 py-2 text-sm font-medium text-flapjack-ink transition-colors hover:bg-flapjack-mint/20 hover:text-flapjack-ink"
					onclick={isMobile ? closeMobileNavAfterNavigation : undefined}
				>
					{item.label}
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			{/each}
		</div>
	</div>
{/snippet}

<!-- P.brand_palette_consistency, M.universal.1: diner brand canvas + desktop sidebar cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__loading__desktop.json -->
<div class="flex h-screen bg-flapjack-cream">
	<aside
		class="hidden w-64 flex-col border-r border-flapjack-ink/15 bg-brand-cream text-flapjack-ink md:flex"
		data-testid="dashboard-nav-desktop"
	>
		<div class="flex h-16 items-center px-6">
			<span class="text-xl font-bold font-['Cabinet']" data-testid="brand-logo">Flapjack Cloud</span
			>
		</div>
		<div class="flex flex-1 flex-col px-3 py-4">
			{@render renderShellNavigation(false)}
		</div>
	</aside>

	<!-- Main content -->
	<div class="flex flex-1 flex-col overflow-hidden">
		<!-- P.brand_palette_consistency, M.universal.1: mobile drawer canvas/text/border palette cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__error__mobile_narrow.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json -->
		<aside
			id="dashboard-mobile-nav-drawer"
			class="fixed inset-y-0 left-0 z-40 flex w-72 flex-col bg-flapjack-cream text-flapjack-ink shadow-xl transition-transform duration-200 md:hidden {mobileNavOpen
				? 'translate-x-0'
				: '-translate-x-full'}"
			data-testid="dashboard-nav-mobile-drawer"
			data-nav-open={mobileNavOpen ? 'true' : 'false'}
			aria-hidden={mobileNavOpen ? 'false' : 'true'}
		>
			{#if mobileNavOpen}
				<div class="flex h-16 items-center justify-between border-b border-flapjack-ink/15 px-4">
					<span class="text-base font-semibold font-['Cabinet']">Flapjack Cloud</span>
					<button
						type="button"
						class="rounded-md px-2 py-1 text-sm font-medium text-flapjack-ink hover:bg-flapjack-mint/20"
						data-testid="dashboard-mobile-nav-dismiss"
						onclick={closeMobileNav}
					>
						Close
					</button>
				</div>
				<div class="flex flex-1 flex-col px-3 py-4">
					{@render renderShellNavigation(true)}
				</div>
			{/if}
		</aside>
		{#if mobileNavOpen}
			<button
				type="button"
				class="fixed inset-0 z-30 bg-flapjack-ink/40 md:hidden"
				aria-label="Dismiss mobile navigation"
				onclick={closeMobileNav}
			></button>
		{/if}

		<!-- Top bar — P.brand_palette_consistency, M.universal.1: cream bg, ink text, and divider cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__mobile_narrow.json -->
		<header
			class="flex h-16 items-center justify-between border-b border-flapjack-ink/15 bg-brand-cream px-6 text-flapjack-ink"
			data-testid="dashboard-shell-header"
		>
			<div class="flex items-center gap-3">
				<button
					type="button"
					class="inline-flex rounded-md border border-flapjack-ink/20 px-2 py-1 text-sm font-medium text-flapjack-ink hover:bg-flapjack-mint/20 md:hidden"
					data-testid="dashboard-mobile-nav-trigger"
					aria-controls="dashboard-mobile-nav-drawer"
					aria-expanded={mobileNavOpen}
					onclick={toggleMobileNav}
				>
					Menu
				</button>
				{#if planContext}
					<span
						class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium {planContext.billing_plan ===
						'free'
							? 'bg-flapjack-ink/10 text-flapjack-ink'
							: 'bg-flapjack-mint/30 text-flapjack-ink'}"
						data-testid="plan-badge"
					>
						{planLabel(planContext.billing_plan)} Plan
					</span>
				{/if}
			</div>
			<div class="flex items-center gap-4">
				<span class="text-sm text-flapjack-ink">{displayName}</span>
				<form method="POST" action="/logout" use:enhance>
					<button
						type="submit"
						class="rounded px-3 py-1 text-sm text-flapjack-ink/80 hover:bg-flapjack-mint/20 hover:text-flapjack-ink"
					>
						Logout
					</button>
				</form>
			</div>
		</header>

		{#if data.impersonation}
			<div
				class="border-b border-flapjack-rose/35 bg-flapjack-rose/10 px-6 py-3"
				data-testid="impersonation-banner"
			>
				<div class="flex items-center justify-between">
					<p class="text-sm font-medium text-flapjack-plum">You are impersonating this customer.</p>
					<!-- This must be a native POST: the response clears auth cookies and
						redirects from the customer dashboard back into the admin area. -->
					<form method="POST" action="/admin/end-impersonation">
						<button
							type="submit"
							data-testid="end-impersonation-button"
							class="rounded-md bg-flapjack-rose px-3 py-1.5 text-sm font-medium text-white hover:bg-flapjack-plum"
						>
							Back to Admin
						</button>
					</form>
				</div>
			</div>
		{/if}

		<div class="border-b border-flapjack-ink/15 bg-flapjack-cream px-6 py-2">
			<BetaSupportBadge dataTestid="dashboard-beta-support-badge" betaLinkLabel="View beta scope" />
		</div>

		{#if showVerificationBanner}
			<!-- P.brand_palette_consistency, M.universal.1, M.palette.7: verification banner moves off generic amber to cream surface + ink text + diner-pink CTA — judgments docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__mobile_narrow.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json -->
			<div
				class="border-b border-flapjack-ink/15 bg-brand-pink px-6 py-3"
				data-testid="verification-banner"
			>
				<div
					class="flex flex-col gap-3 text-sm text-flapjack-ink sm:flex-row sm:items-center sm:justify-between"
				>
					<p>
						Verify your email address to keep full access to dashboard features and account
						recovery.
					</p>
					<button
						type="button"
						class="rounded-md border-2 border-flapjack-ink bg-brand-pink px-3 py-1.5 text-sm font-bold text-flapjack-ink shadow-elevation-button hover:bg-flapjack-plum/80 disabled:cursor-not-allowed disabled:opacity-60"
						data-testid="verification-resend-button"
						disabled={resendInFlight}
						onclick={resendVerificationFromShell}
					>
						{resendInFlight ? 'Sending...' : 'Resend verification email'}
					</button>
				</div>
				{#if resendResultMessage}
					<!-- P.brand_palette_consistency, M.palette.7: success/error resend-result signaling should remain visually distinct; judgments docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json -->
					<p
						class="mt-2 text-sm {resendResultKind === 'error'
							? 'text-flapjack-rose'
							: resendResultKind === 'success'
								? 'text-flapjack-ink'
								: 'text-flapjack-ink'}"
						data-testid="verification-resend-message"
					>
						{resendResultMessage}
					</p>
				{/if}
				{#if resendCooldownSeconds !== null}
					<p class="mt-1 text-sm text-flapjack-ink/80" data-testid="verification-cooldown-copy">
						Try again in {resendCooldownSeconds} seconds.
					</p>
				{/if}
			</div>
		{/if}

		{#if planContext?.billing_plan === 'shared' && planContext.has_payment_method === false && !onBillingRoute}
			<!-- P.brand_palette_consistency, M.palette.7: billing CTA banner aligns with diner palette (cream surface + diner-pink CTA) — judgment docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json -->
			<div
				class="border-b border-flapjack-ink/15 bg-brand-cream px-6 py-3"
				data-testid="billing-cta"
			>
				<div class="flex items-center justify-between">
					<p class="text-sm text-flapjack-ink">
						Your Paid plan requires billing setup to continue.
					</p>
					<a
						href={resolve('/console/billing/setup')}
						class="rounded-md border-2 border-flapjack-ink bg-brand-pink px-3 py-1.5 text-sm font-bold text-flapjack-ink hover:bg-flapjack-plum/80"
					>
						Set up billing
					</a>
				</div>
			</div>
		{/if}

		<!-- Page content -->
		<main class="flex-1 overflow-y-auto p-6">
			{@render children()}
		</main>
	</div>
</div>
