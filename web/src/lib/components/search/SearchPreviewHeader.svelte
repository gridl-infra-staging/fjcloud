<script lang="ts">
	import TrackAnalyticsToggle from './TrackAnalyticsToggle.svelte';
	import VectorStatusBadge from './VectorStatusBadge.svelte';

	let {
		vectorState = 'unavailable',
		trackAnalyticsEnabled = false,
		onTrackAnalyticsChange = () => {},
		onOpenDisplayPreferences = () => {},
		onAddDocuments = () => {}
	}: {
		vectorState?: 'enabled' | 'disabled' | 'unavailable';
		trackAnalyticsEnabled?: boolean;
		onTrackAnalyticsChange?: (nextEnabled: boolean) => void;
		onOpenDisplayPreferences?: () => void;
		onAddDocuments?: () => void;
	} = $props();
</script>

<header class="space-y-3 border-b border-flapjack-ink/15 pb-3" data-testid="search-preview-header">
	<div class="flex items-center justify-between">
		<h2 class="text-lg font-semibold text-flapjack-ink">Search Preview</h2>
		<VectorStatusBadge state={vectorState} />
	</div>

	<div class="flex flex-wrap items-center gap-3">
		<TrackAnalyticsToggle enabled={trackAnalyticsEnabled} {onTrackAnalyticsChange} />
		<button
			type="button"
			class="rounded-md border border-flapjack-ink/20 px-3 py-1 text-sm"
			onclick={onOpenDisplayPreferences}
		>
			Display preferences
		</button>
		<button
			type="button"
			class="rounded-md bg-flapjack-rose px-3 py-1 text-sm text-white hover:bg-flapjack-plum"
			onclick={onAddDocuments}
		>
			Add documents
		</button>
	</div>
</header>
