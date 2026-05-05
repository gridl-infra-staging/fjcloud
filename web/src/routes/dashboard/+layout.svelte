<script lang="ts">
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { DASHBOARD_SESSION_EXPIRED_REDIRECT } from '$lib/auth-session-contracts';
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';
	import { CANONICAL_PUBLIC_API_DOCS_URL } from '$lib/public_api';
	import { parseRetryAfterSeconds, retryAfterSecondsFromHeaders } from '$lib/http/retry_after';

	let { data, children } = $props();

	const planContext = $derived(data.planContext);
	const profile = $derived(data.profile);
	const displayName = $derived(profile?.name || data.user?.customerId || '');

	const navItems = [
		{ href: '/dashboard' as const, label: 'Dashboard', icon: 'home' },
		{ href: '/dashboard/indexes' as const, label: 'Indexes', icon: 'database' },
		{ href: '/dashboard/billing' as const, label: 'Billing', icon: 'credit-card' },
		{ href: '/dashboard/api-keys' as const, label: 'API Keys', icon: 'key' },
		{ href: '/dashboard/logs' as const, label: 'Logs', icon: 'list' },
		{ href: '/dashboard/migrate' as const, label: 'Migrate', icon: 'upload' },
		{ href: '/dashboard/settings' as const, label: 'Settings', icon: 'settings' }
	];
	const supportMailtoHref = `mailto:${SUPPORT_EMAIL}`;
	const helpItems = [
		{ href: supportMailtoHref, label: 'Support', external: false },
		{ href: CANONICAL_PUBLIC_API_DOCS_URL, label: 'API Docs', external: true }
	];

	function isActive(href: string): boolean {
		if (href === '/dashboard') return page.url.pathname === '/dashboard';
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
			const response = await fetch(resolve('/dashboard/resend-verification'), {
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
				class="flex items-center rounded-lg px-3 py-2 text-sm font-medium transition-colors {isMobile
					? isActive(item.href)
						? 'bg-[#9fd8d2]/20 text-[#1f1b18]'
						: 'text-[#1f1b18] hover:bg-[#9fd8d2]/20 hover:text-[#1f1b18]'
					: isActive(item.href)
						? 'bg-[#9fd8d2] text-[#1f1b18]'
						: 'text-[#fff8ea]/80 hover:bg-[#9fd8d2]/20 hover:text-[#fff8ea]'}"
				onclick={isMobile ? closeMobileNavAfterNavigation : undefined}
			>
				{item.label}
			</a>
		{/each}
	</nav>
	<!-- P.brand_palette_consistency, M.universal.1: help section border/label/link tones cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__loading__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json -->
	<div class="mt-6 border-t pt-4 {isMobile ? 'border-[#1f1b18]/20' : 'border-[#fff8ea]/20'}">
		<p
			class="mb-2 text-xs font-semibold uppercase tracking-wide {isMobile
				? 'text-[#1f1b18]/60'
				: 'text-[#fff8ea]/60'}"
		>
			Help
		</p>
		<div class="space-y-1">
			{#each helpItems as item (item.href)}
				<!-- eslint-disable svelte/no-navigation-without-resolve -- support mailto and canonical docs URL are external destinations -->
				<a
					href={item.href}
					target={item.external ? '_blank' : undefined}
					rel={item.external ? 'noreferrer' : undefined}
					class="flex items-center rounded-lg px-3 py-2 text-sm font-medium transition-colors {isMobile
						? 'text-[#1f1b18] hover:bg-[#9fd8d2]/20 hover:text-[#1f1b18]'
						: 'text-[#fff8ea]/80 hover:bg-[#9fd8d2]/20 hover:text-[#fff8ea]'}"
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
<div class="flex h-screen bg-[#fff8ea]">
	<aside
		class="hidden w-64 flex-col bg-[#1f1b18] text-[#fff8ea] md:flex"
		data-testid="dashboard-nav-desktop"
	>
		<div class="flex h-16 items-center px-6">
			<span class="text-xl font-bold">Flapjack Cloud</span>
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
			class="fixed inset-y-0 left-0 z-40 flex w-72 flex-col bg-[#fff8ea] text-[#1f1b18] shadow-xl transition-transform duration-200 md:hidden {mobileNavOpen
				? 'translate-x-0'
				: '-translate-x-full'}"
			data-testid="dashboard-nav-mobile-drawer"
			data-nav-open={mobileNavOpen ? 'true' : 'false'}
			aria-hidden={mobileNavOpen ? 'false' : 'true'}
		>
			{#if mobileNavOpen}
				<div class="flex h-16 items-center justify-between border-b border-[#1f1b18]/15 px-4">
					<span class="text-base font-semibold">Flapjack Cloud</span>
					<button
						type="button"
						class="rounded-md px-2 py-1 text-sm font-medium text-[#1f1b18] hover:bg-[#9fd8d2]/20"
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
				class="fixed inset-0 z-30 bg-[#1f1b18]/40 md:hidden"
				aria-label="Dismiss mobile navigation"
				onclick={closeMobileNav}
			></button>
		{/if}

		<!-- Top bar — P.brand_palette_consistency, M.universal.1: cream bg, ink text, and divider cited by docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__mobile_narrow.json -->
		<header
			class="flex h-16 items-center justify-between border-b border-[#1f1b18]/15 bg-[#fff8ea] px-6"
		>
			<div class="flex items-center gap-3">
				<button
					type="button"
					class="inline-flex rounded-md border border-[#1f1b18]/20 px-2 py-1 text-sm font-medium text-[#1f1b18] hover:bg-[#9fd8d2]/20 md:hidden"
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
							? 'bg-[#1f1b18]/10 text-[#1f1b18]'
							: 'bg-[#9fd8d2]/30 text-[#1f1b18]'}"
						data-testid="plan-badge"
					>
						{planContext.billing_plan === 'free' ? 'Free' : 'Shared'} Plan
					</span>
				{/if}
			</div>
			<div class="flex items-center gap-4">
				<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto: scheme, not an internal path -->
				<a
					href={BETA_FEEDBACK_MAILTO}
					class="text-sm font-medium text-[#1f1b18] underline decoration-[#9fd8d2] hover:decoration-[#1f1b18]"
				>
					Send feedback
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
				<span class="text-sm text-[#1f1b18]">{displayName}</span>
				<form method="POST" action="/logout" use:enhance>
					<button
						type="submit"
						class="rounded px-3 py-1 text-sm text-[#1f1b18]/80 hover:bg-[#9fd8d2]/20 hover:text-[#1f1b18]"
					>
						Logout
					</button>
				</form>
			</div>
		</header>

		{#if data.impersonation}
			<div
				class="border-b border-violet-300 bg-violet-50 px-6 py-3"
				data-testid="impersonation-banner"
			>
				<div class="flex items-center justify-between">
					<p class="text-sm font-medium text-violet-800">You are impersonating this customer.</p>
					<!-- This must be a native POST: the response clears auth cookies and
						redirects from the customer dashboard back into the admin area. -->
					<form method="POST" action="/admin/end-impersonation">
						<button
							type="submit"
							data-testid="end-impersonation-button"
							class="rounded-md bg-violet-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-violet-700"
						>
							Back to Admin
						</button>
					</form>
				</div>
			</div>
		{/if}

		<!-- P.brand_palette_consistency, M.palette.12: beta banner uses diner teal #d9f2ef + rose link tones to share the brand palette with public surfaces — judgment docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__loading__desktop.json -->
		<div
			class="border-b border-[#9fd8d2] bg-[#d9f2ef] px-6 py-3"
			data-testid="dashboard-beta-banner"
		>
			<div
				class="flex flex-col gap-2 text-sm text-[#1f1b18] sm:flex-row sm:items-center sm:justify-between"
			>
				<p>
					Flapjack Cloud is in public beta. Features and limits may change before general
					availability.
				</p>
				<a href={resolve('/beta')} class="font-medium text-[#b83f5f] hover:text-[#8d2842]">
					View beta scope
				</a>
			</div>
		</div>

		{#if showVerificationBanner}
			<!-- P.brand_palette_consistency, M.universal.1, M.palette.7: verification banner moves off generic amber to cream surface + ink text + diner-pink CTA — judgments docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__mobile_narrow.json and docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json -->
			<div
				class="border-b border-[#1f1b18]/15 bg-[#fff8ea] px-6 py-3"
				data-testid="verification-banner"
			>
				<div
					class="flex flex-col gap-3 text-sm text-[#1f1b18] sm:flex-row sm:items-center sm:justify-between"
				>
					<p>
						Verify your email address to keep full access to dashboard features and account
						recovery.
					</p>
					<button
						type="button"
						class="rounded-md border-2 border-[#1f1b18] bg-[#ffb3c7] px-3 py-1.5 text-sm font-bold text-[#1f1b18] hover:bg-[#ffc3d2] disabled:cursor-not-allowed disabled:opacity-60"
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
							? 'text-[#b83f5f]'
							: resendResultKind === 'success'
								? 'text-[#0f766e]'
								: 'text-[#1f1b18]'}"
						data-testid="verification-resend-message"
					>
						{resendResultMessage}
					</p>
				{/if}
				{#if resendCooldownSeconds !== null}
					<p class="mt-1 text-sm text-[#4b4640]" data-testid="verification-cooldown-copy">
						Try again in {resendCooldownSeconds} seconds.
					</p>
				{/if}
			</div>
		{/if}

		{#if planContext?.billing_plan === 'shared' && planContext.has_payment_method === false}
			<!-- P.brand_palette_consistency, M.palette.7: billing CTA banner aligns with diner palette (cream surface + diner-pink CTA) — judgment docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json -->
			<div class="border-b border-[#1f1b18]/15 bg-[#fff8ea] px-6 py-3" data-testid="billing-cta">
				<div class="flex items-center justify-between">
					<p class="text-sm text-[#1f1b18]">Your shared plan requires billing setup to continue.</p>
					<a
						href={resolve('/dashboard/billing')}
						class="rounded-md border-2 border-[#1f1b18] bg-[#ffb3c7] px-3 py-1.5 text-sm font-bold text-[#1f1b18] hover:bg-[#ffc3d2]"
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
