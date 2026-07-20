<script lang="ts">
	import { tick } from 'svelte';
	import {
		INDEX_NAME_MAX_LENGTH,
		proposeDestinationIndexName,
		validateIndexName
	} from '$lib/index-name';
	import type { ApiClient } from '$lib/api/client';
	import type {
		AlgoliaDestinationEligibilityResponse,
		AlgoliaIndexMetadata,
		AlgoliaMigrationCapabilities,
		AlgoliaMigrationDestinationMode,
		CreateAlgoliaImportJobRequest
	} from '$lib/api/types';
	import {
		describeAlgoliaImportAdmission,
		defaultAlgoliaImportAdmission,
		type AlgoliaImportAdmission
	} from './job_presentation';
	import {
		migrationCreateSuccessIntent,
		type MigrationCreateSuccessIntent
	} from './create_success_intent';
	import MigrationCreateReview from './MigrationCreateReview.svelte';
	import { scheduleEligibilityExpiry } from './eligibility';
	import {
		activeProviderEligibility as activeProviderEligibilityForNow,
		defaultProviderEligibility,
		describeProviderEligibility as describeProviderEligibilityState,
		providerEligibilityBinding as buildProviderEligibilityBinding,
		providerEligibilityResponse,
		type ProviderEligibilityState
	} from './provider_eligibility';
	import {
		activeTargetEligibility as activeTargetEligibilityForNow,
		createSubmitIntentBinding,
		matchingTargetEligibility as matchingTargetEligibilityForInputs,
		newMigrationIdempotencyKey,
		targetEligibilityExpired as isTargetEligibilityExpired,
		targetEligibilityInputsBinding as buildTargetEligibilityInputsBinding
	} from './target_eligibility';
	import MigrationAlgoliaConnection from './MigrationAlgoliaConnection.svelte';
	import MigrationProviderEligibility from './MigrationProviderEligibility.svelte';
	import MigrationReplaceDestination from './MigrationReplaceDestination.svelte';
	import MigrationSourceIndexRow from './MigrationSourceIndexRow.svelte';

	type MigrationCreateClient = Pick<
		ApiClient,
		'listAlgoliaSourceIndexes' | 'checkAlgoliaDestinationEligibility' | 'createAlgoliaImportJob'
	>;

	let {
		client,
		providerEligibility = defaultProviderEligibility(),
		admission = defaultAlgoliaImportAdmission(),
		capabilities = undefined,
		onImportCreated = undefined
	}: {
		client: MigrationCreateClient;
		providerEligibility?: ProviderEligibilityState;
		admission?: AlgoliaImportAdmission;
		capabilities?: AlgoliaMigrationCapabilities;
		onImportCreated?: (intent: MigrationCreateSuccessIntent) => void;
	} = $props();

	// Algolia credentials live only in this component's volatile memory: they are
	// never persisted, serialized into markup, or lifted into load data, so a
	// remount deliberately starts blank and forces the customer to reconnect.
	let appId = $state('');
	let apiKey = $state('');

	let sources = $state<AlgoliaIndexMetadata[]>([]);
	let nextCursor = $state<string | null>(null);
	let discoveryError = $state<string | null>(null);
	let activeDiscoveryRequest = $state<{ id: number; providerEligibilityBinding: string } | null>(
		null
	);
	let nextDiscoveryRequestId = 0;
	let searchTerm = $state('');
	let selectedSourceName = $state<string | null>(null);
	let sourceStepHeading = $state<HTMLHeadingElement>();
	let destinationStepHeading = $state<HTMLHeadingElement>();
	let destinationErrorMessage = $state<HTMLParagraphElement>();
	// Seeded from the selected source and then owned by the customer. The proposal
	// is advisory only: whether the destination is actually available is decided
	// by producer target eligibility, never here.
	let destinationName = $state('');
	// Replace mode requires the customer to re-type the fixed existing
	// destination name exactly before Start; the confirmation gates submit only
	// and is never sent to the producer.
	let replaceConfirmation = $state('');
	let targetEligibility = $state<AlgoliaDestinationEligibilityResponse | null>(null);
	let targetEligibilityBinding = $state<string | null>(null);
	let targetEligibilityError = $state<string | null>(null);
	let activeTargetEligibilityRequest = $state<{ id: number; binding: string } | null>(null);
	let nextTargetEligibilityRequestId = 0;
	let submitError = $state<string | null>(null);
	let activeSubmit = $state(false);
	let submitIntentBinding = $state<string | null>(null);
	let submitIntentIdempotencyKey = $state<string | null>(null);
	let successfulSubmitIntentBinding = $state<string | null>(null);
	// Distinguishes "not connected yet" from "connected and the account is empty",
	// which an empty `sources` array alone cannot express.
	let hasDiscovered = $state(false);
	// The credential pair that produced the displayed catalog. Held only to detect
	// edits to the live inputs; it is never rendered, sent, or persisted.
	let connectedAppId = $state('');
	let connectedApiKey = $state('');
	// All volatile connection state belongs to the provider eligibility envelope
	// that made credential entry possible. A refreshed token, expiry, provider,
	// or region starts a new envelope and cannot inherit credentials or cursors.
	let activeProviderEligibilityBinding = $state<string | null>(null);
	let eligibilityNowMillis = $state(Date.now());

	const currentProviderEligibility = $derived(
		activeProviderEligibilityForNow({
			providerEligibility,
			replaceEnabled: capabilities?.replace === true,
			nowMillis: eligibilityNowMillis
		})
	);
	const currentProviderBinding = $derived(
		buildProviderEligibilityBinding(currentProviderEligibility)
	);
	const isDiscovering = $derived(
		activeDiscoveryRequest !== null &&
			activeDiscoveryRequest.providerEligibilityBinding === currentProviderBinding
	);
	const admissionPresentation = $derived(describeAlgoliaImportAdmission(admission));
	const startsDisabled = $derived(admissionPresentation.disablesStarts);
	const hasCredentials = $derived(appId.trim() !== '' && apiKey.trim() !== '');
	const canDiscover = $derived(hasCredentials && !isDiscovering && !startsDisabled);
	// The catalog and `nextCursor` belong to the credentials that fetched them.
	// Once either input is edited the displayed catalog describes an application
	// the customer is no longer pointing at, and replaying the cursor would append
	// another application's page onto this one's list, so treat it as disconnected
	// until the customer reconnects.
	const credentialsChanged = $derived(
		hasDiscovered && (appId !== connectedAppId || apiKey !== connectedApiKey)
	);
	const hasConnected = $derived(sources.length > 0 && !credentialsChanged);
	const canStartReconnect = $derived(hasDiscovered && !credentialsChanged);
	const replaceDestination = $derived(
		currentProviderEligibility?.mode === 'replace' ? currentProviderEligibility.target : null
	);
	const migrationMode = $derived<AlgoliaMigrationDestinationMode>(
		replaceDestination !== null ? 'replace' : 'create'
	);
	const providerEligible = $derived(currentProviderEligibility !== null);
	const providerEligibilityMessage = $derived(
		describeProviderEligibilityState(providerEligibility, currentProviderEligibility)
	);
	// The identity target eligibility is checked against: the customer-edited
	// slug in create mode, or the fixed existing destination in replace mode.
	const eligibilityTargetRegion = $derived(
		replaceDestination !== null
			? replaceDestination.region
			: currentProviderEligibility?.mode === 'create'
				? currentProviderEligibility.target.region
				: null
	);
	const eligibilityTargetName = $derived(
		replaceDestination !== null ? replaceDestination.name : destinationName
	);
	// Only meaningful once a source is chosen in create mode, since that is when
	// the editable destination field exists; replace mode has no editable slug.
	const destinationError = $derived(
		replaceDestination !== null || selectedSourceName === null
			? null
			: validateIndexName(destinationName)
	);
	// Start stays blocked in replace mode until the confirmation matches the
	// producer-provided destination name exactly.
	const replaceConfirmed = $derived(
		replaceDestination === null || replaceConfirmation === replaceDestination.name
	);
	const targetEligibilityInputsBinding = $derived(
		buildTargetEligibilityInputsBinding({
			providerEligibilityBinding: currentProviderEligibility !== null ? currentProviderBinding : null,
			mode: migrationMode,
			sourceName: selectedSourceName,
			destinationName: eligibilityTargetName,
			destinationError,
			region: eligibilityTargetRegion
		})
	);
	const targetEligibilityMatchesInputs = $derived(
		matchingTargetEligibilityForInputs({
			targetEligibility,
			targetEligibilityBinding,
			inputsBinding: targetEligibilityInputsBinding,
			mode: migrationMode,
			destinationName: eligibilityTargetName,
			region: eligibilityTargetRegion
		})
	);
	const currentTargetEligibility = $derived(
		activeTargetEligibilityForNow(targetEligibilityMatchesInputs, eligibilityNowMillis)
	);
	const currentSubmitIntentBinding = $derived(
		currentTargetEligibility === null ? null : submitIntentBindingFor(currentTargetEligibility)
	);
	const isCheckingTargetEligibility = $derived(
		activeTargetEligibilityRequest !== null &&
			activeTargetEligibilityRequest.binding === targetEligibilityInputsBinding
	);
	const canCheckTargetEligibility = $derived(
		targetEligibilityInputsBinding !== null &&
			destinationError === null &&
			!isCheckingTargetEligibility &&
			!activeSubmit &&
			!startsDisabled
	);
	const startImportDisabled = $derived(
		currentTargetEligibility === null ||
			activeSubmit ||
			!replaceConfirmed ||
			(successfulSubmitIntentBinding !== null &&
				successfulSubmitIntentBinding === currentSubmitIntentBinding) ||
			startsDisabled
	);

	// The producer discovery contract carries no query parameter, so search
	// filters the pages already loaded rather than implying a server-side search.
	const visibleSources = $derived(
		searchTerm.trim() === ''
			? sources
			: sources.filter((source) =>
					source.name.toLowerCase().includes(searchTerm.trim().toLowerCase())
				)
	);

	// Selecting a source re-seeds the proposal: an edit made for the previous
	// source is not a choice the customer made about this one.
	async function selectSource(name: string): Promise<void> {
		selectedSourceName = name;
		destinationName = proposeDestinationIndexName(name);
		clearTargetEligibility();
		await tick();
		destinationStepHeading?.focus();
	}

	function handleDestinationInput(): void {
		clearTargetEligibility();
	}

	async function focusDestinationError(): Promise<void> {
		if (destinationError === null) {
			return;
		}
		await tick();
		destinationErrorMessage?.focus();
	}

	function toErrorMessage(error: unknown): string {
		return error instanceof Error ? error.message : String(error);
	}

	function clearSourceSelection(): void {
		selectedSourceName = null;
		destinationName = '';
		clearTargetEligibility();
	}

	function clearSourceCatalog(): void {
		sources = [];
		nextCursor = null;
		clearSourceSelection();
	}

	function clearVolatileConnection(): void {
		appId = '';
		apiKey = '';
		clearSourceCatalog();
		discoveryError = null;
		searchTerm = '';
		hasDiscovered = false;
		connectedAppId = '';
		connectedApiKey = '';
		clearTargetEligibility();
	}

	function clearTargetEligibility(): void {
		targetEligibility = null;
		targetEligibilityBinding = null;
		targetEligibilityError = null;
		submitError = null;
		submitIntentBinding = null;
		submitIntentIdempotencyKey = null;
		successfulSubmitIntentBinding = null;
		replaceConfirmation = '';
	}

	function resetConnection(): void {
		if (isDiscovering || startsDisabled) {
			return;
		}

		clearVolatileConnection();
	}

	function handleConnectAction(): void {
		if (startsDisabled) {
			return;
		}
		if (canStartReconnect) {
			resetConnection();
			return;
		}
		void loadSourcePage(null);
	}

	function liveCredentialsMatch(requestAppId: string, requestApiKey: string): boolean {
		return appId === requestAppId && apiKey === requestApiKey;
	}

	function updateEligibilityClock(nowMillis: number): void {
		if (nowMillis > eligibilityNowMillis) {
			eligibilityNowMillis = nowMillis;
		}
	}

	function targetEligibilityExpired(): boolean {
		return isTargetEligibilityExpired(targetEligibilityMatchesInputs, Date.now());
	}

	function submitIntentBindingFor(
		eligibility: AlgoliaDestinationEligibilityResponse
	): string | null {
		return createSubmitIntentBinding({
			mode: migrationMode,
			sourceName: selectedSourceName,
			destinationName: eligibilityTargetName,
			region: eligibilityTargetRegion,
			targetEligibilityToken: eligibility.eligibilityToken
		});
	}

	function idempotencyKeyFor(binding: string): string {
		if (submitIntentBinding !== binding || submitIntentIdempotencyKey === null) {
			submitIntentBinding = binding;
			submitIntentIdempotencyKey = newMigrationIdempotencyKey();
		}
		return submitIntentIdempotencyKey;
	}

	async function refreshTargetEligibility(): Promise<AlgoliaDestinationEligibilityResponse | null> {
		const provider = currentProviderEligibility;
		const binding = targetEligibilityInputsBinding;
		if (provider === null || binding === null || destinationError !== null) {
			return null;
		}
		const requestId = nextTargetEligibilityRequestId + 1;
		nextTargetEligibilityRequestId = requestId;
		clearTargetEligibility();
		activeTargetEligibilityRequest = { id: requestId, binding };
		try {
			const eligibility = await client.checkAlgoliaDestinationEligibility({
				phase: 'target',
				mode: migrationMode,
				target: { region: provider.target.region, name: eligibilityTargetName },
				eligibilityToken: provider.eligibilityToken
			});
			if (targetEligibilityInputsBinding !== binding) {
				return null;
			}
			const validatedEligibility = activeTargetEligibilityForNow(
				matchingTargetEligibilityForInputs({
					targetEligibility: eligibility,
					targetEligibilityBinding: binding,
					inputsBinding: targetEligibilityInputsBinding,
					mode: migrationMode,
					destinationName: eligibilityTargetName,
					region: eligibilityTargetRegion
				}),
				Date.now()
			);
			if (validatedEligibility === null) {
				targetEligibility = null;
				targetEligibilityBinding = null;
				targetEligibilityError =
					'Destination eligibility no longer matches this import. Check eligibility again.';
				return null;
			}
			targetEligibility = validatedEligibility;
			targetEligibilityBinding = binding;
			submitIntentBinding = null;
			submitIntentIdempotencyKey = null;
			return validatedEligibility;
		} catch (error) {
			if (targetEligibilityInputsBinding === binding) {
				targetEligibilityError = toErrorMessage(error);
				targetEligibility = null;
				targetEligibilityBinding = null;
			}
			return null;
		} finally {
			if (activeTargetEligibilityRequest?.id === requestId) {
				activeTargetEligibilityRequest = null;
			}
		}
	}

	async function ensureFreshTargetEligibility(): Promise<AlgoliaDestinationEligibilityResponse | null> {
		if (targetEligibilityExpired()) {
			return refreshTargetEligibility();
		}
		return currentTargetEligibility;
	}

	async function submitImport(): Promise<void> {
		if (
			activeSubmit ||
			startsDisabled ||
			!replaceConfirmed ||
			(successfulSubmitIntentBinding !== null &&
				successfulSubmitIntentBinding === currentSubmitIntentBinding)
		) {
			return;
		}
		const mode = migrationMode;
		const eligibility = await ensureFreshTargetEligibility();
		const sourceName = selectedSourceName;
		if (eligibility === null || sourceName === null) {
			return;
		}
		const intentBinding = submitIntentBindingFor(eligibility);
		if (intentBinding === null) {
			return;
		}
		const idempotencyKey = idempotencyKeyFor(intentBinding);
		const request: CreateAlgoliaImportJobRequest = {
			mode,
			appId,
			apiKey,
			sourceName,
			target: { eligibilityToken: eligibility.eligibilityToken }
		};
		activeSubmit = true;
		submitError = null;
		try {
			const job = await client.createAlgoliaImportJob(request, idempotencyKey);
			successfulSubmitIntentBinding = intentBinding;
			onImportCreated?.(migrationCreateSuccessIntent(job));
		} catch (error) {
			submitError = toErrorMessage(error);
		} finally {
			activeSubmit = false;
		}
	}

	$effect(() => {
		const providerEligibilityBinding = currentProviderBinding;
		if (
			providerEligibilityBinding === null ||
			(activeProviderEligibilityBinding !== null &&
				activeProviderEligibilityBinding !== providerEligibilityBinding)
		) {
			clearVolatileConnection();
		}
		activeProviderEligibilityBinding = providerEligibilityBinding;
	});

	$effect(() => {
		return scheduleEligibilityExpiry(
			providerEligibilityResponse(providerEligibility),
			updateEligibilityClock
		);
	});

	$effect(() => {
		return scheduleEligibilityExpiry(targetEligibilityMatchesInputs, updateEligibilityClock);
	});

	async function loadSourcePage(cursor: string | null): Promise<void> {
		const requestProviderEligibilityBinding = currentProviderBinding;
		if (
			startsDisabled ||
			requestProviderEligibilityBinding === null ||
			activeDiscoveryRequest?.providerEligibilityBinding === requestProviderEligibilityBinding
		) {
			return;
		}
		// Pin the credentials this request is issued with. The inputs stay editable
		// while the request is in flight, so reading them again after the await
		// would stamp the arriving catalog with credentials that did not fetch it —
		// the guard would then read as connected and hand out a cursor belonging to
		// the previous application.
		const requestAppId = appId;
		const requestApiKey = apiKey;
		const requestId = nextDiscoveryRequestId + 1;
		nextDiscoveryRequestId = requestId;
		activeDiscoveryRequest = {
			id: requestId,
			providerEligibilityBinding: requestProviderEligibilityBinding
		};
		discoveryError = null;
		try {
			const page = await client.listAlgoliaSourceIndexes({
				appId: requestAppId,
				apiKey: requestApiKey,
				...(cursor === null ? {} : { cursor })
			});
			if (currentProviderBinding !== requestProviderEligibilityBinding) {
				return;
			}
			// A first page replaces; a cursor page appends to what is already shown.
			sources = cursor === null ? page.items : [...sources, ...page.items];
			if (cursor === null) {
				clearSourceSelection();
				// A filter typed against the previous application would hide every row
				// of the new one and read as an empty account.
				searchTerm = '';
				connectedAppId = requestAppId;
				connectedApiKey = requestApiKey;
			}
			nextCursor = page.nextCursor;
			hasDiscovered = true;
			if (cursor === null && page.items.length > 0) {
				await tick();
				sourceStepHeading?.focus();
			}
		} catch (error) {
			if (
				currentProviderBinding !== requestProviderEligibilityBinding ||
				!liveCredentialsMatch(requestAppId, requestApiKey)
			) {
				return;
			}
			// Fail closed: a partially-loaded catalog must not be presented as the
			// customer's real source list once discovery has broken. Because this
			// discards the pages already loaded, retry must restart from the first
			// page — replaying the failed cursor would append its page onto an
			// empty list and show that tail as if it were the whole catalog.
			discoveryError = toErrorMessage(error);
			clearSourceCatalog();
		} finally {
			if (activeDiscoveryRequest?.id === requestId) {
				activeDiscoveryRequest = null;
			}
		}
	}
</script>

<div class="space-y-6" data-testid="migration-create-flow">
	<MigrationProviderEligibility eligible={providerEligible} message={providerEligibilityMessage} />

	{#if providerEligible}
		{#if replaceDestination}
			<MigrationReplaceDestination
				name={replaceDestination.name}
				region={replaceDestination.region}
			/>
		{/if}

		<MigrationAlgoliaConnection
			bind:appId
			bind:apiKey
			{startsDisabled}
			{canStartReconnect}
			{isDiscovering}
			{canDiscover}
			{admissionPresentation}
			onConnect={handleConnectAction}
		/>
	{/if}

	{#if providerEligible && isDiscovering}
		<p data-testid="migration-source-loading" class="text-sm text-flapjack-ink/70" role="status">
			Loading source indexes…
		</p>
	{/if}

	{#if providerEligible && discoveryError}
		<div
			data-testid="migration-source-error"
			role="alert"
			class="space-y-3 rounded border border-flapjack-plum/40 p-4"
		>
			<p class="text-sm text-flapjack-plum">{discoveryError}</p>
			<button
				type="button"
				disabled={isDiscovering || startsDisabled}
				onclick={() => loadSourcePage(null)}
				class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium"
			>
				Retry
			</button>
		</div>
	{/if}

	{#if providerEligible && hasConnected}
		<section class="space-y-4" aria-labelledby="migration-source-title">
			<h3
				id="migration-source-title"
				bind:this={sourceStepHeading}
				tabindex="-1"
				class="text-base font-semibold text-flapjack-ink"
			>
				Choose a source index
			</h3>

			<div>
				<label for="migration-source-search" class="mb-1 block text-sm font-medium">
					Search source indexes
				</label>
				<input
					id="migration-source-search"
					type="search"
					bind:value={searchTerm}
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
				/>
			</div>

			<ul data-testid="migration-source-list" class="space-y-2">
				{#each visibleSources as source (source.name)}
					<MigrationSourceIndexRow
						{source}
						selected={selectedSourceName === source.name}
						onSelect={(name) => void selectSource(name)}
					/>
				{/each}
			</ul>

			{#if nextCursor !== null}
				<button
					type="button"
					disabled={isDiscovering || startsDisabled}
					onclick={() => loadSourcePage(nextCursor)}
					class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium"
				>
					Load more source indexes
				</button>
			{/if}

			{#if selectedSourceName}
				<h4
					bind:this={destinationStepHeading}
					tabindex="-1"
					class="text-sm font-semibold text-flapjack-ink"
				>
					Review destination
				</h4>
				<p data-testid="migration-selected-source" class="text-sm text-flapjack-ink">
					Selected source: {selectedSourceName}
				</p>

				{#if replaceDestination}
					<div
						data-testid="migration-selected-replace-destination"
						class="rounded border border-flapjack-ink/20 p-3 text-sm text-flapjack-ink"
					>
						<span class="font-medium">Replacement target</span>:
						{replaceDestination.name} in {replaceDestination.region}
					</div>
				{:else}
					<div>
						<label
							for="migration-destination-name"
							class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>
							Destination index name
						</label>
						<input
							id="migration-destination-name"
							type="text"
							autocomplete="off"
							spellcheck="false"
							maxlength={INDEX_NAME_MAX_LENGTH}
							bind:value={destinationName}
							oninput={handleDestinationInput}
							onchange={focusDestinationError}
							aria-invalid={destinationError !== null}
							aria-describedby={destinationError === null
								? undefined
								: 'migration-destination-error'}
							class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
						/>
						{#if destinationError}
							<p
								id="migration-destination-error"
								data-testid="migration-destination-error"
								bind:this={destinationErrorMessage}
								tabindex="-1"
								class="mt-1 text-sm text-flapjack-plum"
							>
								{destinationError}
							</p>
						{/if}
					</div>
				{/if}
				<div class="space-y-3">
					<button
						type="button"
						disabled={!canCheckTargetEligibility}
						onclick={() => refreshTargetEligibility()}
						class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
					>
						{isCheckingTargetEligibility
							? 'Checking destination eligibility'
							: 'Check destination eligibility'}
					</button>

					{#if targetEligibilityError}
						<p
							data-testid="migration-target-eligibility-error"
							role="alert"
							class="text-sm text-flapjack-plum"
						>
							{targetEligibilityError}
						</p>
					{/if}
				</div>

				{#if currentTargetEligibility}
					<MigrationCreateReview
						mode={migrationMode}
						sourceName={selectedSourceName}
						targetEligibility={currentTargetEligibility}
						{admissionPresentation}
						bind:confirmationName={replaceConfirmation}
						{submitError}
						submitDisabled={startImportDisabled}
						submitting={activeSubmit}
						onSubmit={submitImport}
					/>
				{:else}
					<button
						type="button"
						disabled
						class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white opacity-50"
					>
						Start import
					</button>
				{/if}
			{/if}
		</section>
	{:else if providerEligible && credentialsChanged && !isDiscovering && !discoveryError}
		<p data-testid="migration-credentials-changed" class="text-sm text-flapjack-ink/70">
			These credentials have changed. Connect again to load source indexes.
		</p>
	{:else if providerEligible && hasDiscovered && !isDiscovering && !discoveryError}
		<p data-testid="migration-source-empty" class="text-sm text-flapjack-ink/70">
			This Algolia application has no indexes available to import.
		</p>
	{/if}
</div>
