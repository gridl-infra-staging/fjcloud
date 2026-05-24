<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import SupportReferenceBlock from '$lib/error-boundary/SupportReferenceBlock.svelte';
	import { buildBoundaryCopy } from '$lib/error-boundary/recovery-copy';

	const status = $derived(page.status);
	const errorMessage = $derived(page.error?.message ?? '');
	const supportReference = $derived(page.error?.supportReference);
	const boundaryCopy = $derived(
		buildBoundaryCopy({ status, errorMessage, scope: 'public' }, supportReference)
	);
</script>

<svelte:head>
	<title>{boundaryCopy.heading} — Flapjack Cloud</title>
</svelte:head>

<header class="border-b border-flapjack-ink/20 bg-white">
	<div class="mx-auto flex h-16 max-w-3xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold text-flapjack-ink">Flapjack Cloud</a>
		<nav class="flex items-center gap-4">
			<a
				href={resolve('/login')}
				class="text-sm font-medium text-flapjack-ink/70 hover:text-flapjack-ink">Log In</a
			>
			<!-- Public Sign Up CTA removed during invite-only beta. See docs/decisions/2026_05_23_beta_signup_gate.md -->
		</nav>
	</div>
</header>

<main class="mx-auto max-w-3xl px-6 py-20 text-center">
	<p class="text-6xl font-bold text-flapjack-ink/40">{status}</p>
	<h1 class="mt-4 text-2xl font-bold text-flapjack-ink">{boundaryCopy.heading}</h1>
	<p class="mt-3 text-flapjack-ink/70">{boundaryCopy.description}</p>
	<SupportReferenceBlock {boundaryCopy} />
	<div class="mt-8 flex items-center justify-center gap-4">
		<a
			href={resolve(boundaryCopy.primaryCta.href as '/' | '/console' | '/status')}
			class="rounded-lg bg-flapjack-rose px-6 py-3 text-sm font-semibold text-white shadow hover:bg-flapjack-plum"
		>
			{boundaryCopy.primaryCta.label}
		</a>
		{#if boundaryCopy.showSecondaryStatusLink}
			<a
				href={resolve('/status')}
				class="rounded-lg border border-flapjack-ink/30 bg-white px-6 py-3 text-sm font-semibold text-flapjack-ink/80 shadow hover:bg-flapjack-cream/80"
			>
				Check service status
			</a>
		{/if}
	</div>
</main>
