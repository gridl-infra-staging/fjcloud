<script lang="ts">
	let { name, region }: { name: string; region: string } = $props();
</script>

<section
	class="space-y-3 rounded border border-flapjack-ink/20 p-4"
	aria-labelledby="migration-replace-destination-title"
	data-testid="migration-replace-destination"
>
	<h3 id="migration-replace-destination-title" class="text-base font-semibold text-flapjack-ink">
		Existing destination
	</h3>
	<div class="grid gap-3 sm:grid-cols-2">
		<div>
			<p class="text-xs font-medium uppercase text-flapjack-ink/60">Index</p>
			<p class="text-sm text-flapjack-ink">{name}</p>
		</div>
		<div>
			<p class="text-xs font-medium uppercase text-flapjack-ink/60">Region</p>
			<p class="text-sm text-flapjack-ink">{region}</p>
		</div>
	</div>
</section>
