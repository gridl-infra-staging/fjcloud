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
		? 'flex flex-wrap items-center gap-3 text-sm text-flapjack-ink'
		: 'flex flex-wrap items-center gap-3 text-sm text-flapjack-ink/80'}
>
	<span
		class={compact
			? 'rounded border border-flapjack-ink/40 px-2 py-0.5 text-xs font-bold tracking-widest text-flapjack-ink'
			: 'rounded border border-flapjack-ink/40 px-2 py-0.5 text-xs font-bold tracking-widest text-flapjack-ink/70'}
	>
		BETA
	</span>
	<span>Public beta.</span>
	<a
		href={resolve('/beta')}
		class={compact
			? 'font-medium text-flapjack-rose hover:text-flapjack-plum'
			: 'font-semibold underline hover:text-flapjack-ink'}
	>
		{betaLinkLabel}
	</a>
	<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto: destinations are not internal routes -->
	<a
		href={BETA_FEEDBACK_MAILTO}
		class={compact
			? 'font-medium text-flapjack-ink underline decoration-flapjack-mint hover:decoration-flapjack-ink'
			: 'font-semibold underline hover:text-flapjack-ink'}
	>
		Send feedback
	</a>
	<a
		href={`mailto:${SUPPORT_EMAIL}`}
		class={compact
			? 'font-medium text-flapjack-ink underline decoration-flapjack-mint hover:decoration-flapjack-ink'
			: 'font-semibold underline hover:text-flapjack-ink'}
	>
		Support
	</a>
	<!-- eslint-enable svelte/no-navigation-without-resolve -->
</div>
