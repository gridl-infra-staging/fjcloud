<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
	import { type ServiceStatus, type StatusRouteData } from './status_contract';

	let { data }: { data: StatusRouteData } = $props();

	const statusColors: Record<
		ServiceStatus,
		{ bg: string; border: string; text: string; dot: string }
	> = {
		operational: {
			bg: 'bg-flapjack-mint/25',
			border: 'border-flapjack-mint/60',
			text: 'text-flapjack-ink',
			dot: 'bg-flapjack-mint'
		},
		degraded: {
			bg: 'bg-flapjack-yellow/20',
			border: 'border-flapjack-yellow/50',
			text: 'text-flapjack-ink/80',
			dot: 'bg-flapjack-yellow'
		},
		outage: {
			bg: 'bg-flapjack-rose/10',
			border: 'border-flapjack-rose/35',
			text: 'text-flapjack-plum',
			dot: 'bg-flapjack-rose'
		},
		unknown: {
			bg: 'bg-flapjack-ink/5',
			border: 'border-flapjack-ink/25',
			text: 'text-flapjack-ink/80',
			dot: 'bg-flapjack-ink/40'
		}
	};

	const colors = $derived(statusColors[data.status]);

	function formatTimestamp(iso: string): string {
		return new Date(iso).toLocaleString();
	}
</script>

<svelte:head>
	<title>Service Status - Flapjack Cloud</title>
</svelte:head>

<header class="border-b border-flapjack-ink/20 bg-white">
	<div class="mx-auto flex h-16 max-w-3xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold text-flapjack-ink">Flapjack Cloud</a>
		<nav class="flex items-center gap-4">
			<a
				href={resolve('/login')}
				class="text-sm font-medium text-flapjack-ink/70 hover:text-flapjack-ink">Log In</a
			>
			<!-- Signup discovery is withdrawn; see decisions/2026-05-23_beta_signup_gate.md. -->
		</nav>
	</div>
</header>

<main class="mx-auto max-w-3xl px-6 py-12">
	<h1 class="text-2xl font-bold text-flapjack-ink">Service Status</h1>

	<div
		data-testid="status-badge"
		class={`mt-6 flex items-center gap-3 rounded-lg border p-5 ${colors.bg} ${colors.border}`}
	>
		<span class={`h-3 w-3 rounded-full ${colors.dot}`}></span>
		<span class={`text-lg font-semibold ${colors.text}`}>{data.statusLabel}</span>
	</div>

	{#if data.lastUpdated}
		<p data-testid="status-last-updated" class="mt-4 text-sm text-flapjack-ink/60">
			Last updated: {formatTimestamp(data.lastUpdated)}
		</p>
	{/if}
	{#if data.message}
		<p data-testid="status-incident-message" class="mt-2 text-sm text-flapjack-ink/80">
			{data.message}
		</p>
	{/if}

	<div class="mt-10 rounded-lg border border-flapjack-ink/20 bg-white p-6">
		<h2 class="text-lg font-semibold text-flapjack-ink">About this page</h2>
		<p class="mt-2 text-sm text-flapjack-ink/70">
			This page reflects the current operational status of Flapjack Cloud services. During
			incidents, this page is updated with the latest information.
		</p>
		<p class="mt-3 text-sm text-flapjack-ink/70">
			Flapjack Cloud operations owns incident updates for this page. Public beta support targets a
			response within 48 business hours.
		</p>
		<p class="mt-4">
			<!-- There is no incident-history route yet; link to beta scope so
					customers can see the currently promised support/status contract. -->
			<!-- eslint-disable svelte/no-navigation-without-resolve -->
			<a
				href={resolve('/beta')}
				class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
			>
				View beta scope
			</a>
			<span class="mx-2 text-flapjack-ink/40">|</span>
			<a
				href={BETA_FEEDBACK_MAILTO}
				class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
			>
				Email support
			</a>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</p>
	</div>
</main>
