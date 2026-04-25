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
	<h2 class="mb-4 text-lg font-medium text-gray-900">Personalization</h2>
	<p class="mb-4 text-sm text-gray-600">
		Manage personalization strategy and inspect per-user profiles.
	</p>

	{#if personalizationStrategySaved}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Strategy saved.
		</div>
	{/if}

	{#if personalizationStrategyDeleted}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Strategy deleted.
		</div>
	{/if}

	{#if personalizationProfileDeleted}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Profile deleted.
		</div>
	{/if}

	{#if personalizationError}
		<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{personalizationError}</div>
	{/if}

	<div class="mb-6 rounded-md border border-gray-200 p-4">
		<h3 class="mb-3 text-sm font-semibold text-gray-900">Strategy</h3>
		<form method="POST" action="?/savePersonalizationStrategy" use:enhance>
			<label
				for="personalization-strategy-json"
				class="mb-2 block text-sm font-medium text-gray-700">Strategy JSON</label
			>
			<textarea
				id="personalization-strategy-json"
				name="strategy"
				bind:value={strategyText}
				rows="14"
				class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			></textarea>

			<div class="flex flex-wrap items-center gap-3">
				<button
					type="submit"
					class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
				>
					Save Strategy
				</button>
				<button
					type="submit"
					formaction="?/deletePersonalizationStrategy"
					class="rounded-md border border-red-300 px-4 py-2 text-sm font-medium text-red-700 hover:bg-red-50"
				>
					Delete Strategy
				</button>
			</div>
		</form>
	</div>

	<div class="rounded-md border border-gray-200 p-4">
		<h3 class="mb-3 text-sm font-semibold text-gray-900">Profile Lookup</h3>
		<form method="POST" action="?/getPersonalizationProfile" use:enhance class="mb-4 flex gap-3">
			<input
				type="text"
				name="userToken"
				bind:value={profileUserToken}
				placeholder="userToken"
				class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			/>
			<button
				type="submit"
				class="rounded-md border border-gray-300 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-100"
			>
				Load Profile
			</button>
		</form>

		{#if personalizationProfile}
			<div class="rounded-md border border-gray-200 bg-gray-50 p-3">
				<p class="mb-2 text-sm font-medium text-gray-900">{personalizationProfile.userToken}</p>
				<pre
					class="mb-3 overflow-x-auto whitespace-pre-wrap rounded bg-white p-3 font-mono text-xs text-gray-700">{JSON.stringify(
						personalizationProfile,
						null,
						2
					)}</pre>
				<form method="POST" action="?/deletePersonalizationProfile" use:enhance>
					<input type="hidden" name="userToken" value={personalizationProfile.userToken} />
					<button
						type="submit"
						class="rounded-md border border-red-300 px-3 py-1 text-sm font-medium text-red-700 hover:bg-red-50"
					>
						Delete Profile
					</button>
				</form>
			</div>
		{:else}
			<p class="text-sm text-gray-500">No profile loaded.</p>
		{/if}
	</div>
</div>
