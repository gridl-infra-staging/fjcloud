<script lang="ts">
	let {
		enabled = false,
		onTrackAnalyticsChange = () => {}
	}: {
		enabled?: boolean;
		onTrackAnalyticsChange?: (nextEnabled: boolean) => void;
	} = $props();
</script>

<label class="inline-flex items-center gap-2 text-sm text-flapjack-ink">
	<input
		type="checkbox"
		checked={enabled}
		aria-label="Record preview activity in Analytics"
		onchange={(event) => onTrackAnalyticsChange((event.currentTarget as HTMLInputElement).checked)}
	/>
	Record preview activity in Analytics
</label>
