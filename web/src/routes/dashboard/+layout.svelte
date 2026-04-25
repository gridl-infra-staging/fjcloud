<script lang="ts">
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { DASHBOARD_SESSION_EXPIRED_REDIRECT } from '$lib/auth-session-contracts';
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';

	let { data, children } = $props();

	const planContext = $derived(data.planContext);
	const profile = $derived(data.profile);
	const displayName = $derived(profile?.name || data.user?.customerId || '');

	const navItems = [
		{ href: '/dashboard' as const, label: 'Dashboard', icon: 'home' },
		{ href: '/dashboard/indexes' as const, label: 'Indexes', icon: 'database' },
		{ href: '/dashboard/database' as const, label: 'Database', icon: 'database' },
		{ href: '/dashboard/billing' as const, label: 'Billing', icon: 'credit-card' },
		{ href: '/dashboard/api-keys' as const, label: 'API Keys', icon: 'key' },
		{ href: '/dashboard/logs' as const, label: 'Logs', icon: 'list' },
		{ href: '/dashboard/migrate' as const, label: 'Migrate', icon: 'upload' },
		{ href: '/dashboard/settings' as const, label: 'Settings', icon: 'settings' }
	];

	function isActive(href: string): boolean {
		if (href === '/dashboard') return page.url.pathname === '/dashboard';
		return page.url.pathname.startsWith(href);
	}

	function hasSessionExpiredFormMarker(form: unknown): form is { _authSessionExpired: true } {
		if (typeof form !== 'object' || form === null) return false;
		return (form as Record<string, unknown>)._authSessionExpired === true;
	}

	let redirectedForSessionExpiry = $state(false);
	$effect(() => {
		if (redirectedForSessionExpiry) return;
		if (!hasSessionExpiredFormMarker(page.form)) return;
		redirectedForSessionExpiry = true;
		// eslint-disable-next-line svelte/no-navigation-without-resolve -- DASHBOARD_SESSION_EXPIRED_REDIRECT carries a query string (`?reason=...`) that resolve() rejects as a typed route literal; the path itself is statically owned by $lib/auth-session-contracts.
		void goto(DASHBOARD_SESSION_EXPIRED_REDIRECT);
	});
</script>

<div class="flex h-screen bg-gray-100">
	<!-- Sidebar -->
	<aside class="flex w-64 flex-col bg-gray-900 text-white">
		<div class="flex h-16 items-center px-6">
			<span class="text-xl font-bold">Flapjack Cloud</span>
		</div>

		<nav class="flex-1 space-y-1 px-3 py-4">
			{#each navItems as item (item.href)}
				<a
					href={resolve(item.href)}
					class="flex items-center rounded-lg px-3 py-2 text-sm font-medium transition-colors {isActive(
						item.href
					)
						? 'bg-gray-800 text-white'
						: 'text-gray-300 hover:bg-gray-800 hover:text-white'}"
				>
					{item.label}
				</a>
			{/each}
		</nav>
	</aside>

	<!-- Main content -->
	<div class="flex flex-1 flex-col overflow-hidden">
		<!-- Top bar -->
		<header class="flex h-16 items-center justify-between border-b border-gray-200 bg-white px-6">
			<div class="flex items-center gap-3">
				{#if planContext}
					<span
						class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium {planContext.billing_plan ===
						'free'
							? 'bg-gray-100 text-gray-700'
							: 'bg-blue-100 text-blue-700'}"
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
					class="text-sm font-medium text-blue-600 hover:text-blue-800"
				>
					Send feedback
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
				<span class="text-sm text-gray-700">{displayName}</span>
				<form method="POST" action="/logout" use:enhance>
					<button
						type="submit"
						class="rounded px-3 py-1 text-sm text-gray-600 hover:bg-gray-100 hover:text-gray-900"
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

		<div class="border-b border-blue-200 bg-blue-50 px-6 py-3" data-testid="dashboard-beta-banner">
			<div
				class="flex flex-col gap-2 text-sm text-blue-900 sm:flex-row sm:items-center sm:justify-between"
			>
				<p>
					Flapjack Cloud is in public beta. Features and limits may change before general
					availability.
				</p>
				<a href={resolve('/beta')} class="font-medium text-blue-700 hover:text-blue-900">
					View beta scope
				</a>
			</div>
		</div>

		{#if planContext?.billing_plan === 'shared' && planContext.has_payment_method === false}
			<div class="border-b border-amber-200 bg-amber-50 px-6 py-3" data-testid="billing-cta">
				<div class="flex items-center justify-between">
					<p class="text-sm text-amber-800">Your shared plan requires billing setup to continue.</p>
					<a
						href={resolve('/dashboard/billing')}
						class="rounded-md bg-amber-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-700"
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
