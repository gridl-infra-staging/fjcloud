<script lang="ts">
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import SupportReferenceBlock from '$lib/error-boundary/SupportReferenceBlock.svelte';
	import { buildBoundaryCopy } from '$lib/error-boundary/recovery-copy';

	const status = $derived(page.status);
	const errorMessage = $derived(page.error?.message ?? '');
	const supportReference = $derived(page.error?.supportReference);
	const boundaryCopy = $derived(
		buildBoundaryCopy({ status, errorMessage, scope: 'dashboard' }, supportReference)
	);
</script>

<div
	class="flex flex-col items-center justify-center border-2 border-[#1f1b18]/15 bg-[#fff8ea] py-20 text-center"
>
	<p class="text-6xl font-bold text-[#1f1b18]/25">{status}</p>
	<h1 class="mt-4 text-2xl font-bold text-[#1f1b18]">{boundaryCopy.heading}</h1>
	<p class="mt-3 max-w-md text-[#4b4640]">{boundaryCopy.description}</p>
	<SupportReferenceBlock {boundaryCopy} containerClass="w-full max-w-md" />
	<div class="mt-8 flex items-center gap-4">
		<a
			href={resolve(boundaryCopy.primaryCta.href)}
			class="rounded-lg border-2 border-[#1f1b18] bg-[#ffb3c7] px-6 py-3 text-sm font-semibold text-[#1f1b18] shadow hover:bg-[#ffc3d2]"
		>
			{boundaryCopy.primaryCta.label}
		</a>
		{#if boundaryCopy.showSecondaryStatusLink}
			<a
				href={resolve('/status')}
				class="rounded-lg border-2 border-[#1f1b18] bg-[#fff8ea] px-6 py-3 text-sm font-semibold text-[#1f1b18] shadow hover:bg-[#f7efdc]"
			>
				Check service status
			</a>
		{/if}
	</div>
</div>
