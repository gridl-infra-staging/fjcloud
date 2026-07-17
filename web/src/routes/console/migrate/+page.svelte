<script lang="ts">
	import { SUPPORT_EMAIL } from '$lib/format';
	import type { AlgoliaMigrationAvailabilityResponse } from '$lib/api/types';

	let { data } = $props<{
		data: {
			availability: AlgoliaMigrationAvailabilityResponse;
		};
	}>();

	const availability = $derived(data.availability);
</script>

<svelte:head>
	<title>Migrate from Algolia</title>
</svelte:head>

<div class="space-y-6">
	<header class="space-y-2">
		<h2 class="text-xl font-semibold text-flapjack-ink">Migrate from Algolia</h2>
		<p class="max-w-3xl text-sm leading-6 text-flapjack-ink/70">
			Direct imports from Algolia are paused while we replace the importer with a safer migration
			path.
		</p>
	</header>

	<section
		data-testid="migration-unavailable"
		class="rounded-md border border-flapjack-ink/20 bg-white p-5"
		aria-labelledby="migration-unavailable-title"
	>
		<div class="space-y-3">
			<p id="migration-unavailable-title" class="text-base font-semibold text-flapjack-ink">
				Algolia migration is temporarily unavailable
			</p>
			<p class="text-sm leading-6 text-flapjack-ink/75">
				{availability.message}
			</p>
			<p class="text-sm leading-6 text-flapjack-ink/75">
				We have temporarily turned off new Algolia imports while we replace the customer import
				flow. Existing fjcloud indexes and search APIs continue to work.
			</p>
			<p class="text-sm leading-6 text-flapjack-ink/75">
				For migration planning help while this is unavailable, contact
				<a
					class="font-medium text-flapjack-rose hover:text-flapjack-plum"
					href={`mailto:${SUPPORT_EMAIL}`}
				>
					{SUPPORT_EMAIL}
				</a>.
			</p>
		</div>
	</section>
</div>
