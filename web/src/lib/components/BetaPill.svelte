<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';

	let { dataTestid } = $props<{ dataTestid?: string }>();
</script>

<div data-testid={dataTestid} class="flex flex-wrap items-center gap-3 text-sm text-[#1f1b18]">
	<span
		class="rounded border border-[#1f1b18]/40 px-2 py-0.5 text-xs font-bold tracking-widest text-[#1f1b18]"
	>
		BETA
	</span>
	<span>Public beta.</span>
	<a href={resolve('/beta')} class="font-medium text-[#b83f5f] hover:text-[#8d2842]"
		>View beta scope</a
	>
	<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto: destinations are not internal routes -->
	<a
		href={BETA_FEEDBACK_MAILTO}
		class="font-medium text-[#1f1b18] underline decoration-[#9fd8d2] hover:decoration-[#1f1b18]"
	>
		Send feedback
	</a>
	<a
		href={`mailto:${SUPPORT_EMAIL}`}
		class="font-medium text-[#1f1b18] underline decoration-[#9fd8d2] hover:decoration-[#1f1b18]"
	>
		Support
	</a>
	<!-- eslint-enable svelte/no-navigation-without-resolve -->
</div>
