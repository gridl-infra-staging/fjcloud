<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import SupportReferenceBlock from '$lib/error-boundary/SupportReferenceBlock.svelte';
	import { buildBoundaryCopy } from '$lib/error-boundary/recovery-copy';

	const status = $derived(page.status);
	const errorMessage = $derived(page.error?.message ?? '');
	const supportReference = $derived(page.error?.supportReference);
	// scope: 'dashboard' is an internal taxonomy literal for boundary copy
	// selection (see BoundaryScope in $lib/error-boundary/recovery-copy.ts).
	// It is NOT a URL segment and must remain 'dashboard' after the
	// /dashboard -> /console route-owner move — renaming changes every
	// persisted support reference.
	const boundaryCopy = $derived(
		buildBoundaryCopy({ status, errorMessage, scope: 'dashboard' }, supportReference)
	);
</script>

<div
	class="flex flex-col items-center justify-center border-2 border-flapjack-ink/15 bg-flapjack-cream py-20 text-center"
>
	<p class="text-6xl font-bold text-flapjack-ink/25">{status}</p>
	<h1 class="mt-4 text-2xl font-bold text-flapjack-ink">{boundaryCopy.heading}</h1>
	<p class="mt-3 max-w-md text-flapjack-ink/80">{boundaryCopy.description}</p>
	<SupportReferenceBlock {boundaryCopy} containerClass="w-full max-w-md" />
	<div class="mt-8 flex items-center gap-4">
		<a
			href={resolve(boundaryCopy.primaryCta.href as '/' | '/console' | '/status')}
			class="rounded-lg border-2 border-flapjack-ink bg-brand-pink px-6 py-3 text-sm font-semibold text-flapjack-ink shadow hover:bg-flapjack-plum/80"
		>
			{boundaryCopy.primaryCta.label}
		</a>
		{#if boundaryCopy.showSecondaryStatusLink}
			<a
				href={resolve('/status')}
				class="rounded-lg border-2 border-flapjack-ink bg-flapjack-cream px-6 py-3 text-sm font-semibold text-flapjack-ink shadow hover:bg-flapjack-cream/80"
			>
				Check service status
			</a>
		{/if}
	</div>
</div>
