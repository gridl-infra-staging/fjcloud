<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index, PersonalizationProfile, PersonalizationStrategy } from '$lib/api/types';

	type Props = {
		index: Index;
		personalizationStrategy: PersonalizationStrategy | null;
		personalizationProfile: PersonalizationProfile | null;
		personalizationError: string;
		personalizationStrategySaved: boolean;
		personalizationStrategyDeleted: boolean;
		personalizationProfileDeleted: boolean;
	};

	let {
		index,
		personalizationStrategy,
		personalizationProfile,
		personalizationError,
		personalizationStrategySaved,
		personalizationStrategyDeleted,
		personalizationProfileDeleted
	}: Props = $props();

	const defaultStrategy: PersonalizationStrategy = {
		eventsScoring: [
			{ eventName: 'Product viewed', eventType: 'view', score: 10 },
			{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
		],
		facetsScoring: [
			{ facetName: 'brand', score: 70 },
			{ facetName: 'category', score: 30 }
		],
		personalizationImpact: 75
	};

	const strategyFromServerText = $derived(
		JSON.stringify(personalizationStrategy ?? defaultStrategy, null, 2)
	);
	let strategyText = $state('');
	let lastHydratedStrategyText = $state('');
	let profileUserToken = $state('');

	$effect(() => {
		if (strategyFromServerText !== lastHydratedStrategyText) {
			strategyText = strategyFromServerText;
			lastHydratedStrategyText = strategyFromServerText;
		}

		if (personalizationProfile?.userToken) {
			profileUserToken = personalizationProfile.userToken;
		}
	});
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="personalization-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Personalization</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Manage personalization strategy and inspect per-user profiles.
	</p>

	{#if personalizationStrategySaved}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Strategy saved.
		</div>
	{/if}

	{#if personalizationStrategyDeleted}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Strategy deleted.
		</div>
	{/if}

	{#if personalizationProfileDeleted}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Profile deleted.
		</div>
	{/if}

	{#if personalizationError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{personalizationError}
		</div>
	{/if}

	<div class="mb-6 rounded-md border border-flapjack-ink/20 p-4">
		<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Strategy</h3>
		<form method="POST" action="?/savePersonalizationStrategy" use:enhance>
			<label
				for="personalization-strategy-json"
				class="mb-2 block text-sm font-medium text-flapjack-ink/80">Strategy JSON</label
			>
			<textarea
				id="personalization-strategy-json"
				name="strategy"
				bind:value={strategyText}
				rows="14"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			></textarea>

			<div class="flex flex-wrap items-center gap-3">
				<button
					type="submit"
					class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				>
					Save Strategy
				</button>
				<button
					type="submit"
					formaction="?/deletePersonalizationStrategy"
					class="rounded-md border border-flapjack-rose/45 px-4 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
				>
					Delete Strategy
				</button>
			</div>
		</form>
	</div>

	<div class="rounded-md border border-flapjack-ink/20 p-4">
		<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Profile Lookup</h3>
		<form method="POST" action="?/getPersonalizationProfile" use:enhance class="mb-4 flex gap-3">
			<input
				type="text"
				name="userToken"
				bind:value={profileUserToken}
				placeholder="userToken"
				class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>
			<button
				type="submit"
				class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
			>
				Load Profile
			</button>
		</form>

		{#if personalizationProfile}
			<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-3">
				<p class="mb-2 text-sm font-medium text-flapjack-ink">{personalizationProfile.userToken}</p>
				<pre
					class="mb-3 overflow-x-auto whitespace-pre-wrap rounded bg-white p-3 font-mono text-xs text-flapjack-ink/80">{JSON.stringify(
						personalizationProfile,
						null,
						2
					)}</pre>
				<form method="POST" action="?/deletePersonalizationProfile" use:enhance>
					<input type="hidden" name="userToken" value={personalizationProfile.userToken} />
					<button
						type="submit"
						class="rounded-md border border-flapjack-rose/45 px-3 py-1 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
					>
						Delete Profile
					</button>
				</form>
			</div>
		{:else}
			<p class="text-sm text-flapjack-ink/60">No profile loaded.</p>
		{/if}
	</div>
</div>
