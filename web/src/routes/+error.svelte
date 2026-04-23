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

<header class="border-b border-gray-200 bg-white">
	<div class="mx-auto flex h-16 max-w-3xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold text-gray-900">Flapjack Cloud</a>
		<nav class="flex items-center gap-4">
			<a href={resolve('/login')} class="text-sm font-medium text-gray-600 hover:text-gray-900"
				>Log In</a
			>
			<a
				href={resolve('/signup')}
				class="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Sign Up
			</a>
		</nav>
	</div>
</header>

<main class="mx-auto max-w-3xl px-6 py-20 text-center">
	<p class="text-6xl font-bold text-gray-300">{status}</p>
	<h1 class="mt-4 text-2xl font-bold text-gray-900">{boundaryCopy.heading}</h1>
	<p class="mt-3 text-gray-600">{boundaryCopy.description}</p>
	<SupportReferenceBlock {boundaryCopy} />
	<div class="mt-8 flex items-center justify-center gap-4">
		<a
			href={resolve(boundaryCopy.primaryCta.href)}
			class="rounded-lg bg-blue-600 px-6 py-3 text-sm font-semibold text-white shadow hover:bg-blue-700"
		>
			{boundaryCopy.primaryCta.label}
		</a>
		{#if boundaryCopy.showSecondaryStatusLink}
			<a
				href={resolve('/status')}
				class="rounded-lg border border-gray-300 bg-white px-6 py-3 text-sm font-semibold text-gray-700 shadow hover:bg-gray-50"
			>
				Check service status
			</a>
		{/if}
	</div>
</main>
