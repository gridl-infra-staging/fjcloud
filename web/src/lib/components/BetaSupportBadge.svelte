<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';

	let {
		betaLinkLabel = 'Learn about the beta',
		compact = true,
		dataTestid
	} = $props<{
		betaLinkLabel?: string;
		compact?: boolean;
		dataTestid?: string;
	}>();
</script>

<div
	data-testid={dataTestid}
	class={compact
		? 'flex flex-wrap items-center gap-3 text-sm text-[#1f1b18]'
		: 'flex flex-wrap items-center gap-3 text-sm text-gray-700'}
>
	<span
		class={compact
			? 'rounded border border-[#1f1b18]/40 px-2 py-0.5 text-xs font-bold tracking-widest text-[#1f1b18]'
			: 'rounded border border-gray-400 px-2 py-0.5 text-xs font-bold tracking-widest text-gray-600'}
	>
		BETA
	</span>
	<span>Public beta.</span>
	<a
		href={resolve('/beta')}
		class={compact ? 'font-medium text-[#b83f5f] hover:text-[#8d2842]' : 'font-semibold underline hover:text-gray-900'}
	>
		{betaLinkLabel}
	</a>
	<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto: destinations are not internal routes -->
	<a
		href={BETA_FEEDBACK_MAILTO}
		class={compact
			? 'font-medium text-[#1f1b18] underline decoration-[#9fd8d2] hover:decoration-[#1f1b18]'
			: 'font-semibold underline hover:text-gray-900'}
	>
		Send feedback
	</a>
	<a
		href={`mailto:${SUPPORT_EMAIL}`}
		class={compact
			? 'font-medium text-[#1f1b18] underline decoration-[#9fd8d2] hover:decoration-[#1f1b18]'
			: 'font-semibold underline hover:text-gray-900'}
	>
		Support
	</a>
	<!-- eslint-enable svelte/no-navigation-without-resolve -->
</div>
