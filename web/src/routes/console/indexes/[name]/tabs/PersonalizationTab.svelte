<script lang="ts">
	import { enhance } from '$app/forms';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type { EditorDialogOnSave } from '$lib/components/EditorDialog.types';
	import type { Index, PersonalizationProfile, PersonalizationStrategy } from '$lib/api/types';
	import {
		defaultPersonalizationStrategy,
		normalizePersonalizationStrategy,
		personalizationStrategyDialogSchema,
		serializePersonalizationStrategy,
		strategyFromDialogValue,
		strategyToDialogValue
	} from './personalization_strategy_dialog';

	type Props = {
		index: Index;
		personalizationStrategy: PersonalizationStrategy | null;
		personalizationProfile: PersonalizationProfile | null;
		personalizationError: string;
		personalizationStrategySaved: boolean;
		personalizationStrategyDeleted: boolean;
		personalizationProfileDeleted: boolean;
		personalizationProfileLookupInFlight: boolean;
		personalizationProfileLookupAttempted: boolean;
	};

	let {
		index,
		personalizationStrategy,
		personalizationProfile,
		personalizationError,
		personalizationStrategySaved,
		personalizationStrategyDeleted,
		personalizationProfileDeleted,
		personalizationProfileLookupInFlight,
		personalizationProfileLookupAttempted
	}: Props = $props();

	type StrategyState = 'untouched' | 'saved' | 'deleted' | 'error';
	type ProfileState = 'untouched' | 'loading' | 'found' | 'empty' | 'error';
	type ProfileMetadataRow = {
		label: string;
		value: string;
		rowTestId: string;
		valueTestId: string;
	};
	type ProfileScoreEntry = {
		facetValue: string;
		score: number;
		entryTestId: string;
		valueTestId: string;
	};
	type ProfileScoreCategory = {
		categoryName: string;
		categoryTestId: string;
		entries: ProfileScoreEntry[];
	};

	const testIdEncoder = new TextEncoder();

	function toTestIdSegment(value: string): string {
		const encodedValue = Array.from(testIdEncoder.encode(value), (byte) =>
			byte.toString(16).padStart(2, '0')
		).join('');
		return `u${encodedValue}`;
	}

	const strategyState = $derived.by<StrategyState>(() => {
		if (personalizationError) return 'error';
		if (personalizationStrategyDeleted) return 'deleted';
		if (personalizationStrategySaved) return 'saved';
		return 'untouched';
	});
	const profileState = $derived.by<ProfileState>(() => {
		if (personalizationError) return 'error';
		if (personalizationProfileLookupInFlight) return 'loading';
		if (personalizationProfile) return 'found';
		if (personalizationProfileLookupAttempted) return 'empty';
		return 'untouched';
	});
	const profileMetadataRows = $derived.by<ProfileMetadataRow[]>(() => {
		if (!personalizationProfile) return [];
		const metadataRows: ProfileMetadataRow[] = [
			{
				label: 'User token',
				value: personalizationProfile.userToken,
				rowTestId: 'personalization-profile-metadata-row-user-token',
				valueTestId: 'personalization-profile-user-token'
			}
		];
		if (personalizationProfile.lastEventAt) {
			metadataRows.push({
				label: 'Last event at',
				value: personalizationProfile.lastEventAt,
				rowTestId: 'personalization-profile-metadata-row-last-event-at',
				valueTestId: 'personalization-profile-metadata-value-last-event-at'
			});
		}
		return metadataRows;
	});
	const profileScoreCategories = $derived.by<ProfileScoreCategory[]>(() => {
		if (!personalizationProfile) return [];
		const categories: ProfileScoreCategory[] = [];
		for (const [categoryName, categoryScores] of Object.entries(personalizationProfile.scores)) {
			const categorySegment = toTestIdSegment(categoryName);
			const entries = Object.entries(categoryScores)
				.filter(([, score]) => typeof score === 'number' && Number.isFinite(score))
				.map(([facetValue, score]) => {
					const facetSegment = toTestIdSegment(facetValue);
					return {
						facetValue,
						score,
						entryTestId: `personalization-profile-score-entry-${categorySegment}-${facetSegment}`,
						valueTestId: `personalization-profile-score-value-${categorySegment}-${facetSegment}`
					};
				});
			categories.push({
				categoryName,
				categoryTestId: `personalization-profile-score-category-${categorySegment}`,
				entries
			});
		}
		return categories;
	});

	let strategyDialogOpen = $state(false);
	let showDeleteStrategyConfirmDialog = $state(false);
	let pendingDeleteStrategyForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteStrategyTrigger = $state<HTMLElement | null>(null);
	let strategyDeleteSubmissionResolver = $state<(() => void) | null>(null);

	let showDeleteProfileConfirmDialog = $state(false);
	let pendingDeleteProfileForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteProfileTrigger = $state<HTMLElement | null>(null);
	let profileDeleteSubmissionResolver = $state<(() => void) | null>(null);

	let strategyDraft = $state<PersonalizationStrategy>(defaultPersonalizationStrategy);
	let strategyPayloadText = $state('');
	let strategyPayloadError = $state('');
	let lastHydratedStrategyPayloadText = $state('');
	let lastHydratedStrategySignature = $state('');
	let strategyImpact = $state(0);
	let strategyEventsRows = $state(0);
	let strategyFacetRows = $state(0);
	let profileUserToken = $state('');

	const strategySaveDisabled = $derived(
		strategyPayloadError.length > 0 || strategyPayloadText === lastHydratedStrategyPayloadText
	);

	$effect(() => {
		const sourceSignature = JSON.stringify(personalizationStrategy ?? null);
		if (sourceSignature !== lastHydratedStrategySignature) {
			const normalized = normalizePersonalizationStrategy(personalizationStrategy);
			strategyDraft = normalized.strategy;
			strategyPayloadText = serializePersonalizationStrategy(normalized.strategy);
			lastHydratedStrategyPayloadText = strategyPayloadText;
			lastHydratedStrategySignature = sourceSignature;
			strategyPayloadError = normalized.error;
			strategyImpact = normalized.strategy.personalizationImpact;
			strategyEventsRows = normalized.strategy.eventsScoring.length;
			strategyFacetRows = normalized.strategy.facetsScoring.length;
		}

		if (personalizationProfile?.userToken) {
			profileUserToken = personalizationProfile.userToken;
		}
	});

	const onStrategyDialogSave: EditorDialogOnSave = async (dialogValue) => {
		const strategy = strategyFromDialogValue(dialogValue);
		strategyDraft = strategy;
		strategyPayloadText = serializePersonalizationStrategy(strategy);
		strategyPayloadError = '';
		strategyImpact = strategy.personalizationImpact;
		strategyEventsRows = strategy.eventsScoring.length;
		strategyFacetRows = strategy.facetsScoring.length;
		strategyDialogOpen = false;
	};

	function openStrategyDialog(): void {
		strategyDialogOpen = true;
	}

	function closeStrategyDialog(): void {
		strategyDialogOpen = false;
	}

	function openDeleteStrategyConfirmDialog(form: HTMLFormElement, trigger: HTMLElement): void {
		pendingDeleteStrategyForm = form;
		pendingDeleteStrategyTrigger = trigger;
		showDeleteStrategyConfirmDialog = true;
	}

	function closeDeleteStrategyConfirmDialog(): void {
		showDeleteStrategyConfirmDialog = false;
		pendingDeleteStrategyForm = null;
		pendingDeleteStrategyTrigger = null;
	}

	function finalizeDeleteStrategyConfirmDialog(): void {
		strategyDeleteSubmissionResolver?.();
		strategyDeleteSubmissionResolver = null;
		closeDeleteStrategyConfirmDialog();
	}

	function confirmDeleteStrategy(): Promise<void> {
		const form = pendingDeleteStrategyForm;
		if (!form) return Promise.resolve();
		return new Promise((resolve) => {
			strategyDeleteSubmissionResolver = resolve;
			form.requestSubmit();
		});
	}

	function openDeleteProfileConfirmDialog(form: HTMLFormElement, trigger: HTMLElement): void {
		pendingDeleteProfileForm = form;
		pendingDeleteProfileTrigger = trigger;
		showDeleteProfileConfirmDialog = true;
	}

	function closeDeleteProfileConfirmDialog(): void {
		showDeleteProfileConfirmDialog = false;
		pendingDeleteProfileForm = null;
		pendingDeleteProfileTrigger = null;
	}

	function finalizeDeleteProfileConfirmDialog(): void {
		profileDeleteSubmissionResolver?.();
		profileDeleteSubmissionResolver = null;
		closeDeleteProfileConfirmDialog();
	}

	function confirmDeleteProfile(): Promise<void> {
		const form = pendingDeleteProfileForm;
		if (!form) return Promise.resolve();
		return new Promise((resolve) => {
			profileDeleteSubmissionResolver = resolve;
			form.requestSubmit();
		});
	}

	$effect(() => {
		if (!strategyDeleteSubmissionResolver) return;
		if (personalizationStrategyDeleted || personalizationError) {
			finalizeDeleteStrategyConfirmDialog();
		}
	});

	$effect(() => {
		if (!profileDeleteSubmissionResolver) return;
		if (personalizationProfileDeleted || personalizationError) {
			finalizeDeleteProfileConfirmDialog();
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

	<div class="mb-6 rounded-md border border-flapjack-ink/20 p-4">
		<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Strategy</h3>
		{#if strategyState === 'error'}
			<div
				class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
				data-testid="personalization-strategy-state-error"
			>
				{personalizationError}
			</div>
		{:else if strategyState === 'deleted'}
			<div
				class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
				data-testid="personalization-strategy-state-deleted"
			>
				Strategy deleted.
			</div>
		{:else if strategyState === 'saved'}
			<div
				class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
				data-testid="personalization-strategy-state-saved"
			>
				Strategy saved.
			</div>
		{:else}
			<p
				class="mb-4 text-sm text-flapjack-ink/60"
				data-testid="personalization-strategy-state-untouched"
			>
				No strategy changes yet.
			</p>
		{/if}

		{#if strategyPayloadError}
			<div
				class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
				data-testid="personalization-strategy-invalid-state"
			>
				Strategy validation error: {strategyPayloadError}
			</div>
		{/if}

		<div class="mb-4 rounded-md bg-flapjack-cream/65 p-3 text-sm text-flapjack-ink/80">
			<p data-testid="personalization-strategy-summary-impact">
				Impact: <span class="font-medium">{strategyImpact}</span>
			</p>
			<p data-testid="personalization-strategy-summary-events">
				Event scoring rows: <span class="font-medium">{strategyEventsRows}</span>
			</p>
			<p data-testid="personalization-strategy-summary-facets">
				Facet scoring rows: <span class="font-medium">{strategyFacetRows}</span>
			</p>
		</div>

		<div class="mb-4">
			<button
				type="button"
				onclick={openStrategyDialog}
				class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
			>
				Edit Strategy
			</button>
		</div>

		<form
			method="POST"
			action="?/savePersonalizationStrategy"
			use:enhance
			data-testid="personalization-strategy-save-form"
		>
			<input type="hidden" name="strategy" value={strategyPayloadText} />
			<div class="flex flex-wrap items-center">
				<button
					type="submit"
					data-testid="personalization-strategy-save"
					disabled={strategySaveDisabled}
					class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
				>
					Save Strategy
				</button>
			</div>
		</form>

		<form
			method="POST"
			action="?/deletePersonalizationStrategy"
			use:enhance
			class="mt-3"
			data-testid="personalization-strategy-delete-form"
		>
			<button
				type="button"
				onclick={(event) =>
					openDeleteStrategyConfirmDialog(
						(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
						event.currentTarget as HTMLElement
					)}
				class="rounded-md border border-flapjack-rose/45 px-4 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
			>
				Delete Strategy
			</button>
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

		{#if profileState === 'error'}
			<div
				class="rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
				data-testid="personalization-profile-state-error"
			>
				{personalizationError}
			</div>
		{:else if profileState === 'loading'}
			<p class="text-sm text-flapjack-ink/60" data-testid="personalization-profile-state-loading">
				Loading profile…
			</p>
		{:else if profileState === 'found' && personalizationProfile}
			<div
				class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-3"
				data-testid="personalization-profile-state-found"
			>
				<div class="rounded-md border border-flapjack-ink/10 bg-white/80 p-3">
					<p class="mb-3 text-sm font-semibold text-flapjack-ink">Profile details</p>
					<dl class="space-y-2">
						{#each profileMetadataRows as metadataRow (metadataRow.rowTestId)}
							<div
								class="grid grid-cols-[8rem_1fr] gap-2 text-sm"
								data-testid={metadataRow.rowTestId}
							>
								<dt class="text-flapjack-ink/60">{metadataRow.label}</dt>
								<dd class="font-medium text-flapjack-ink" data-testid={metadataRow.valueTestId}>
									{metadataRow.value}
								</dd>
							</div>
						{/each}
					</dl>
				</div>
				<div class="mt-3">
					<p class="mb-2 text-sm font-semibold text-flapjack-ink">Score categories</p>
					<div class="grid gap-3 md:grid-cols-2">
						{#each profileScoreCategories as category (category.categoryTestId)}
							<div
								class="rounded-md border border-flapjack-ink/10 bg-white/70 p-3"
								data-testid={category.categoryTestId}
							>
								<p
									class="mb-2 text-sm font-medium text-flapjack-ink"
									data-testid="personalization-profile-score-category-title"
								>
									{category.categoryName}
								</p>
								<ul class="space-y-1 text-sm">
									{#each category.entries as entry (entry.entryTestId)}
										<li
											class="flex items-center justify-between gap-3"
											data-testid={entry.entryTestId}
										>
											<span class="text-flapjack-ink/75">{entry.facetValue}</span>
											<span class="font-medium text-flapjack-ink" data-testid={entry.valueTestId}
												>{entry.score}</span
											>
										</li>
									{/each}
								</ul>
							</div>
						{/each}
					</div>
				</div>
				<form method="POST" action="?/deletePersonalizationProfile" use:enhance>
					<input type="hidden" name="userToken" value={personalizationProfile.userToken} />
					<button
						type="button"
						onclick={(event) =>
							openDeleteProfileConfirmDialog(
								(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
								event.currentTarget as HTMLElement
							)}
						class="rounded-md border border-flapjack-rose/45 px-3 py-1 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
					>
						Delete Profile
					</button>
				</form>
			</div>
		{:else if profileState === 'empty'}
			<p class="text-sm text-flapjack-ink/60" data-testid="personalization-profile-state-empty">
				{personalizationProfileDeleted
					? 'Profile deleted.'
					: 'No personalization profile found for this user token.'}
			</p>
		{:else}
			<p class="text-sm text-flapjack-ink/60" data-testid="personalization-profile-state-untouched">
				No profile loaded.
			</p>
		{/if}
	</div>
</div>

<ConfirmDialog
	open={showDeleteStrategyConfirmDialog && pendingDeleteStrategyForm !== null}
	mode="standard"
	dangerLevel="severe"
	title="Delete strategy?"
	consequences="Deleting this strategy permanently removes personalization weighting for this index."
	rationale="You can create a new strategy draft after deletion."
	entityName={index.name}
	confirmLabel="Delete strategy"
	cancelLabel="Cancel"
	onCancel={closeDeleteStrategyConfirmDialog}
	onConfirm={confirmDeleteStrategy}
	triggerRef={pendingDeleteStrategyTrigger}
/>

<ConfirmDialog
	open={showDeleteProfileConfirmDialog && pendingDeleteProfileForm !== null}
	mode="standard"
	dangerLevel="severe"
	title="Delete profile?"
	consequences="Deleting this profile permanently removes saved user personalization scores."
	rationale="Reload or re-run lookup to verify the profile stays deleted."
	entityName={personalizationProfile?.userToken ?? profileUserToken}
	confirmLabel="Delete profile"
	cancelLabel="Cancel"
	onCancel={closeDeleteProfileConfirmDialog}
	onConfirm={confirmDeleteProfile}
	triggerRef={pendingDeleteProfileTrigger}
/>

<EditorDialog
	title="Edit personalization strategy"
	mode="edit"
	schema={personalizationStrategyDialogSchema}
	initialValue={strategyToDialogValue(strategyDraft)}
	open={strategyDialogOpen}
	onSave={onStrategyDialogSave}
	onCancel={closeStrategyDialog}
	description="Update event and facet weighting, then save the strategy to the server."
	submitLabel="Apply changes"
	testId="personalization-strategy-editor-dialog"
/>
