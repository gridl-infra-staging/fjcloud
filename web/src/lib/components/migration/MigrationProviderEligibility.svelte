<script lang="ts">
	let {
		eligible,
		message
	}: {
		eligible: boolean;
		message: string;
	} = $props();
</script>

<section class="space-y-3" aria-labelledby="migration-provider-title">
	<h3 id="migration-provider-title" class="text-base font-semibold text-flapjack-ink">
		Destination eligibility
	</h3>
	<p
		data-testid="migration-provider-eligibility"
		class="text-sm text-flapjack-ink/70"
		role={eligible ? 'status' : 'alert'}
	>
		{message}
	</p>
</section>
