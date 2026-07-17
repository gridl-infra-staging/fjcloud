<script lang="ts">
	import TrackAnalyticsToggle from './TrackAnalyticsToggle.svelte';
	import VectorStatusBadge from './VectorStatusBadge.svelte';
	import Tooltip from '../Tooltip.svelte';

	const TRACK_ANALYTICS_TOOLTIP =
		'When enabled, preview searches and explicit result opens are recorded for this index and may appear in Analytics. When disabled, preview searches are excluded.';

	let {
		vectorState = 'unavailable',
		trackAnalyticsEnabled = false,
		analyticsStatusMessage = '',
		onTrackAnalyticsChange = () => {},
		merchModeEnabled = false,
		onMerchModeChange = () => {},
		onAddDocuments = () => {}
	}: {
		vectorState?: 'enabled' | 'disabled' | 'unavailable';
		trackAnalyticsEnabled?: boolean;
		analyticsStatusMessage?: string;
		onTrackAnalyticsChange?: (nextEnabled: boolean) => void;
		merchModeEnabled?: boolean;
		onMerchModeChange?: (nextEnabled: boolean) => void;
		onAddDocuments?: () => void;
	} = $props();
</script>

<header class="space-y-3 border-b border-flapjack-ink/15 pb-3" data-testid="search-preview-header">
	<div class="flex items-center justify-end">
		<VectorStatusBadge state={vectorState} />
	</div>

	<div class="flex flex-wrap items-center gap-3">
		<span class="inline-flex items-center gap-1">
			<TrackAnalyticsToggle enabled={trackAnalyticsEnabled} {onTrackAnalyticsChange} />
			<Tooltip
				triggerLabel="About Track Analytics"
				message={TRACK_ANALYTICS_TOOLTIP}
				idBase="search-track-analytics"
			/>
		</span>
		<label class="inline-flex items-center gap-2 text-sm text-flapjack-ink">
			<input
				type="checkbox"
				checked={merchModeEnabled}
				aria-label="Merchandising mode"
				onchange={(event) => onMerchModeChange((event.currentTarget as HTMLInputElement).checked)}
			/>
			Merchandising mode
		</label>
		<button
			type="button"
			class="rounded-md bg-flapjack-rose px-3 py-1 text-sm text-white hover:bg-flapjack-plum"
			onclick={onAddDocuments}
		>
			Add documents
		</button>
	</div>
	{#if analyticsStatusMessage}
		<p class="text-sm text-flapjack-plum" role="status">{analyticsStatusMessage}</p>
	{/if}
</header>
