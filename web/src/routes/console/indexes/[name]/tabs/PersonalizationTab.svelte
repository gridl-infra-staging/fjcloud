<script lang="ts">
	import { enhance } from '$app/forms';
	import { copyToClipboard } from '$lib/clipboard';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import type { EditorDialogOnSave } from '$lib/components/EditorDialog.types';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import type { Index, PersonalizationProfile, PersonalizationStrategy } from '$lib/api/types';
	import {
		defaultPersonalizationStrategy,
		normalizePersonalizationStrategy,
		personalizationStrategyDialogSchema,
		serializePersonalizationStrategy,
		strategyFromDialogValue,
		strategyToDialogValue
	} from './personalization_strategy_dialog';
	import type { PersonalizationStrategyInvalidState } from './personalization_strategy_dialog';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';

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

	type StrategyState = 'untouched' | 'error';
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
	const personalizationImpactTooltip =
		'Controls how strongly personalization reorders matching results.';
	const eventScoringRowsTooltip =
		'Event rows map user behavior events to scores used by the strategy.';
	const facetScoringRowsTooltip =
		'Facet rows weight profile facets that influence personalized ranking.';
	const profileUserTokenTooltip =
		'Lookup requires the same stable userToken sent with search and event requests.';

	function toTestIdSegment(value: string): string {
		const encodedValue = Array.from(testIdEncoder.encode(value), (byte) =>
			byte.toString(16).padStart(2, '0')
		).join('');
		return `u${encodedValue}`;
	}

	const strategyState = $derived.by<StrategyState>(() => {
		if (personalizationError) return 'error';
		return 'untouched';
	});
	const profileState = $derived.by<ProfileState>(() => {
		if (personalizationError) return 'error';
		if (personalizationProfileLookupInFlight) return 'loading';
		if (personalizationProfile) return 'found';
		if (personalizationProfileDeleted) return 'untouched';
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
	let strategyInvalidState = $state<PersonalizationStrategyInvalidState | null>(null);
	let lastHydratedStrategyPayloadText = $state('');
	let lastHydratedStrategySignature = $state('');
	let strategyImpact = $state(0);
	let strategyEventsRows = $state(0);
	let strategyFacetRows = $state(0);
	let profileUserToken = $state('');
	let lastPersonalizationStrategySavedToastState = $state(false);
	let lastPersonalizationStrategyDeletedToastState = $state(false);
	let lastPersonalizationProfileDeletedToastState = $state(false);

	const strategySaveDisabled = $derived(
		strategyPayloadError.length > 0 || strategyPayloadText === lastHydratedStrategyPayloadText
	);
	const strategyExamplePayloadText = $derived(
		strategyInvalidState
			? serializePersonalizationStrategy(strategyInvalidState.exampleStrategy)
			: ''
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
			strategyInvalidState = normalized.invalidState;
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
		strategyInvalidState = null;
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

	function copyStrategyExample(event: MouseEvent): void {
		void copyToClipboard(
			strategyExamplePayloadText,
			event.currentTarget as HTMLButtonElement,
			'Example copied'
		);
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

	$effect(() => {
		if (personalizationStrategySaved && !lastPersonalizationStrategySavedToastState) {
			toast.success('Strategy saved.', { duration: TOAST_DURATION_MS });
		}
		lastPersonalizationStrategySavedToastState = personalizationStrategySaved;

		if (personalizationStrategyDeleted && !lastPersonalizationStrategyDeletedToastState) {
			toast.success('Strategy deleted.', { duration: TOAST_DURATION_MS });
		}
		lastPersonalizationStrategyDeletedToastState = personalizationStrategyDeleted;

		if (personalizationProfileDeleted && !lastPersonalizationProfileDeletedToastState) {
			toast.success('Profile deleted.', { duration: TOAST_DURATION_MS });
		}
		lastPersonalizationProfileDeletedToastState = personalizationProfileDeleted;
	});
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.personalization}
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
				class="mb-4 rounded-md border border-flapjack-rose/25 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
				data-testid="personalization-strategy-invalid-state"
			>
				<p class="font-medium">The saved personalization strategy could not be loaded.</p>
				<p class="mt-1">
					The editor is showing a default strategy so you can repair and save a valid version.
				</p>
				<div class="mt-3 rounded-md border border-flapjack-ink/10 bg-white/85 p-3">
					<p class="mb-2 text-xs font-semibold uppercase text-flapjack-ink/60">Example JSON</p>
					<pre
						class="max-h-56 overflow-auto whitespace-pre-wrap break-words text-xs text-flapjack-ink"
						data-testid="personalization-strategy-example-json">{strategyExamplePayloadText}</pre>
					<button
						type="button"
						data-testid="personalization-strategy-copy-example"
						onclick={copyStrategyExample}
						class="mt-3 rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
					>
						Copy example personalization strategy
					</button>
				</div>
			</div>
		{/if}

		<div class="mb-4 rounded-md bg-flapjack-cream/65 p-3 text-sm text-flapjack-ink/80">
			<p
				class="flex items-center justify-between gap-3"
				data-testid="personalization-strategy-summary-impact"
			>
				<span class="inline-flex items-center gap-2">
					Impact:
					<Tooltip
						triggerLabel="What personalization impact means"
						message={personalizationImpactTooltip}
						idBase="personalization-impact"
					/>
				</span>
				<span class="font-medium">{strategyImpact}</span>
			</p>
			<p
				class="mt-2 flex items-center justify-between gap-3"
				data-testid="personalization-strategy-summary-events"
			>
				<span class="inline-flex items-center gap-2">
					Event scoring rows:
					<Tooltip
						triggerLabel="What event scoring rows mean"
						message={eventScoringRowsTooltip}
						idBase="personalization-event-scoring-rows"
					/>
				</span>
				<span class="font-medium">{strategyEventsRows}</span>
			</p>
			<p
				class="mt-2 flex items-center justify-between gap-3"
				data-testid="personalization-strategy-summary-facets"
			>
				<span class="inline-flex items-center gap-2">
					Facet scoring rows:
					<Tooltip
						triggerLabel="What facet scoring rows mean"
						message={facetScoringRowsTooltip}
						idBase="personalization-facet-scoring-rows"
					/>
				</span>
				<span class="font-medium">{strategyFacetRows}</span>
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
		<form
			method="POST"
			action="?/getPersonalizationProfile"
			use:enhance
			class="mb-4 flex items-end gap-3"
		>
			<div class="min-w-0 flex-1">
				<label
					for="personalization-profile-user-token-input"
					class="mb-1 flex items-center gap-2 text-sm font-medium text-flapjack-ink/70"
				>
					userToken
					<Tooltip
						triggerLabel="What profile lookup userToken means"
						message={profileUserTokenTooltip}
						idBase="personalization-profile-user-token"
					/>
				</label>
				<input
					id="personalization-profile-user-token-input"
					type="text"
					name="userToken"
					bind:value={profileUserToken}
					placeholder="userToken"
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
				/>
			</div>
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
				No personalization profile found for this user token.
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
