<script lang="ts">
	import { tick, untrack } from 'svelte';
	import { proposeDestinationIndexName } from '$lib/index-name';
	import type {
		AlgoliaDestinationEligibilityResponse,
		AlgoliaIndexMetadata,
		AlgoliaMigrationCapabilities,
		CreateMigrationImportJobRequest,
		SourceProvider
	} from '$lib/api/types';
	import {
		describeAlgoliaImportAdmission,
		defaultAlgoliaImportAdmission,
		describeMigrationPreviewFailure,
		migrationPreviewCompatibilityWarningPresentation
	} from './job_presentation';
	import type { AlgoliaImportAdmission } from './job_presentation';
	import { migrationCreateSuccessIntent } from './create_success_intent';
	import type { MigrationCreateSuccessIntent } from './create_success_intent';
	import {
		checkMigrationDestination,
		createMigrationJob,
		listMigrationSources,
		migrationSourceCredentials,
		sourceCredentialFingerprint
	} from './migration_create_client';
	import type { MigrationCreateClient } from './migration_create_client';
	import {
		clearMigrationPreviewState,
		createMigrationPreviewState,
		markMigrationPreviewError,
		migrationPreviewArguments,
		requestMigrationPreview
	} from './migration_create_preview_state';
	import MigrationCreateDestination from './MigrationCreateDestination.svelte';
	import { scheduleEligibilityExpiry } from './eligibility';
	import {
		activeProviderEligibility as activeProviderEligibilityForNow,
		defaultProviderEligibility,
		describeProviderEligibility as describeProviderEligibilityState,
		providerEligibilityBinding as buildProviderEligibilityBinding,
		providerEligibilityResponse
	} from './provider_eligibility';
	import type { ProviderEligibilityState } from './provider_eligibility';
	import {
		activeTargetEligibility as activeTargetEligibilityForNow,
		createSubmitIntentBinding,
		matchingTargetEligibility as matchingTargetEligibilityForInputs,
		newMigrationIdempotencyKey,
		targetEligibilityExpired as isTargetEligibilityExpired,
		targetEligibilityInputsBinding as buildTargetEligibilityInputsBinding
	} from './target_eligibility';
	import MigrationProviderEligibility from './MigrationProviderEligibility.svelte';
	import MigrationReplaceDestination from './MigrationReplaceDestination.svelte';
	import MigrationSourceConnection from './MigrationSourceConnection.svelte';
	import MigrationSourceIndexRow from './MigrationSourceIndexRow.svelte';
	import { migrationCreateDestinationState } from './migration_create_flow_state';
	import { toErrorMessage } from './migration_error_redaction';
	let {
		client,
		sourceProvider = $bindable<SourceProvider>('algolia'),
		providerEligibility = defaultProviderEligibility(),
		admission = defaultAlgoliaImportAdmission(),
		capabilities = undefined,
		onImportCreated = undefined
	}: {
		client: MigrationCreateClient;
		sourceProvider?: SourceProvider;
		providerEligibility?: ProviderEligibilityState;
		admission?: AlgoliaImportAdmission;
		capabilities?: AlgoliaMigrationCapabilities;
		onImportCreated?: (intent: MigrationCreateSuccessIntent) => void;
	} = $props();
	// Source credentials stay in volatile component memory, never markup or load
	// data. A remount deliberately starts blank and requires reconnection.
	let appId = $state('');
	let host = $state('');
	let apiKey = $state('');
	let sources = $state<AlgoliaIndexMetadata[]>([]);
	let nextCursor = $state<string | null>(null);
	let discoveryError = $state<string | null>(null);
	let activeDiscoveryRequest = $state<{
		id: number;
		providerEligibilityBinding: string;
		sourceProvider: SourceProvider;
	} | null>(null);
	let nextDiscoveryRequestId = 0;
	let searchTerm = $state('');
	let selectedSourceName = $state<string | null>(null);
	let sourceStepHeading = $state<HTMLHeadingElement>();
	// Seeded from the source, then customer-owned; producer eligibility decides
	// whether this advisory proposal is actually available.
	let destinationName = $state('');
	// Replace confirmation gates submit locally and is never sent to the producer.
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
	let previewState = $state(createMigrationPreviewState());
	// An empty source array cannot distinguish unconnected from an empty account.
	let hasDiscovered = $state(false);
	// Retain the non-secret identity, but only a one-way fingerprint of the key.
	let connectedSourceIdentity = $state('');
	let connectedApiKeyFingerprint = $state<string | null>(null);
	let liveApiKeyFingerprint = $state<string | null>(null);
	let credentialRevision = 0;
	// A changed eligibility envelope cannot inherit credentials or cursors.
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
	const sourceIdentity = $derived(sourceProvider === 'algolia' ? appId : host);
	const hasCredentials = $derived(sourceIdentity.trim() !== '' && apiKey.trim() !== '');
	const canDiscover = $derived(hasCredentials && !isDiscovering && !startsDisabled);
	// Catalog and cursor belong to their credential pair; any edit disconnects
	// them so one source's page cannot append to another source's catalog.
	const credentialsChanged = $derived(
		hasDiscovered &&
			(sourceIdentity !== connectedSourceIdentity ||
				liveApiKeyFingerprint !== connectedApiKeyFingerprint)
	);
	const hasConnected = $derived(sources.length > 0 && !credentialsChanged);
	const canStartReconnect = $derived(hasDiscovered && !credentialsChanged);
	const destinationState = $derived(
		migrationCreateDestinationState({
			currentProviderEligibility,
			selectedSourceName,
			destinationName,
			replaceConfirmation
		})
	);
	const replaceDestination = $derived(destinationState.replaceDestination);
	const migrationMode = $derived(destinationState.migrationMode);
	const providerEligible = $derived(currentProviderEligibility !== null);
	const providerEligibilityMessage = $derived(
		describeProviderEligibilityState(providerEligibility, currentProviderEligibility)
	);
	const eligibilityTargetRegion = $derived(destinationState.eligibilityTargetRegion);
	const eligibilityTargetName = $derived(destinationState.eligibilityTargetName);
	const destinationError = $derived(destinationState.destinationError);
	const replaceConfirmed = $derived(destinationState.replaceConfirmed);
	const targetEligibilityInputsBindingWithoutProvider = $derived(
		buildTargetEligibilityInputsBinding({
			providerEligibilityBinding:
				currentProviderEligibility !== null ? currentProviderBinding : null,
			mode: migrationMode,
			sourceName: selectedSourceName,
			destinationName: eligibilityTargetName,
			destinationError,
			region: eligibilityTargetRegion
		})
	);
	const targetEligibilityInputsBinding = $derived(
		targetEligibilityInputsBindingWithoutProvider === null
			? null
			: `${sourceProvider}:${targetEligibilityInputsBindingWithoutProvider}`
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
	const previewSupported = $derived(capabilities?.preview === true);
	const currentPreviewSatisfied = $derived(
		!previewSupported || previewAttemptMatches(currentSubmitIntentBinding)
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
			!currentPreviewSatisfied ||
			activeSubmit ||
			!replaceConfirmed ||
			(successfulSubmitIntentBinding !== null &&
				successfulSubmitIntentBinding === currentSubmitIntentBinding) ||
			startsDisabled
	);
	const currentPreviewResult = $derived(
		previewState.binding !== null && previewState.binding === currentSubmitIntentBinding
			? previewState.result
			: null
	);
	const currentPreviewError = $derived(
		previewState.attemptBinding !== null &&
			previewState.attemptBinding === currentSubmitIntentBinding &&
			previewState.error !== null
			? describeMigrationPreviewFailure(sourceProvider, previewState.error)
			: null
	);
	// Both a failed preview request and a successful report carrying hard
	// rejections warn that the import may fail or omit data. Neither blocks the
	// import, so both surface the advisory start label.
	const previewWarnsImportMayFail = $derived(
		currentPreviewError !== null || (currentPreviewResult?.report.summary.hardRejections ?? 0) > 0
	);
	const previewWarningPresentation = $derived(
		currentPreviewResult === null
			? null
			: migrationPreviewCompatibilityWarningPresentation(currentPreviewResult)
	);
	const isPreviewing = $derived(previewState.activeRequest);

	// Discovery has no query parameter, so search filters only loaded pages.
	const visibleSources = $derived(
		searchTerm.trim() === ''
			? sources
			: sources.filter((source) =>
					source.name.toLowerCase().includes(searchTerm.trim().toLowerCase())
				)
	);

	// A new source re-seeds its destination proposal.
	async function selectSource(name: string): Promise<void> {
		selectedSourceName = name;
		destinationName = proposeDestinationIndexName(name);
		clearTargetEligibility();
	}

	function handleDestinationInput(name: string): void {
		destinationName = name;
		clearTargetEligibility();
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

	function clearConnectionState(): void {
		clearSourceCatalog();
		discoveryError = null;
		searchTerm = '';
		connectedSourceIdentity = '';
		connectedApiKeyFingerprint = null;
		liveApiKeyFingerprint = null;
		clearTargetEligibility();
	}

	function clearVolatileConnection(): void {
		appId = '';
		host = '';
		apiKey = '';
		clearConnectionState();
		hasDiscovered = false;
	}

	function handleCredentialsChange(): void {
		credentialRevision += 1;
		const hadConnectionState =
			hasDiscovered ||
			sources.length > 0 ||
			nextCursor !== null ||
			selectedSourceName !== null ||
			targetEligibility !== null ||
			submitIntentIdempotencyKey !== null;
		clearConnectionState();
		hasDiscovered = hadConnectionState;
	}

	function selectSourceProvider(nextProvider: SourceProvider): void {
		if (nextProvider === sourceProvider) {
			return;
		}
		clearVolatileConnection();
		sourceProvider = nextProvider;
	}

	function clearTargetEligibility(options?: { preserveReplaceConfirmation?: boolean }): void {
		targetEligibility = null;
		targetEligibilityBinding = null;
		targetEligibilityError = null;
		submitError = null;
		clearMigrationPreviewState(previewState);
		submitIntentBinding = null;
		submitIntentIdempotencyKey = null;
		successfulSubmitIntentBinding = null;
		if (!options?.preserveReplaceConfirmation) {
			replaceConfirmation = '';
		}
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

	function liveCredentialsMatch(
		requestProvider: SourceProvider,
		requestIdentity: string,
		requestApiKey: string
	): boolean {
		return (
			sourceProvider === requestProvider &&
			sourceIdentity === requestIdentity &&
			apiKey === requestApiKey
		);
	}

	function updateEligibilityClock(nowMillis: number): void {
		if (nowMillis > untrack(() => eligibilityNowMillis)) {
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

	function previewAttemptMatches(binding: string | null): boolean {
		return binding !== null && previewState.attemptBinding === binding;
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
		clearTargetEligibility({ preserveReplaceConfirmation: true });
		activeTargetEligibilityRequest = { id: requestId, binding };
		try {
			const request = {
				phase: 'target',
				mode: migrationMode,
				target: { region: provider.target.region, name: eligibilityTargetName },
				eligibilityToken: provider.eligibilityToken
			} as const;
			const eligibility = await checkMigrationDestination(client, sourceProvider, request);
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
			clearMigrationPreviewState(previewState);
			submitIntentBinding = null;
			submitIntentIdempotencyKey = null;
			return validatedEligibility;
		} catch (error) {
			if (targetEligibilityInputsBinding === binding) {
				targetEligibilityError = toErrorMessage(error, [provider.eligibilityToken]);
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
	async function runPreview(): Promise<void> {
		if (startsDisabled || !previewSupported) return;
		await requestMigrationPreview(previewState, {
			client,
			currentBinding: () => currentSubmitIntentBinding,
			prepare: async () => {
				const mode = migrationMode;
				const eligibility = await ensureFreshTargetEligibility();
				const sourceName = selectedSourceName;
				if (eligibility === null || sourceName === null) return null;
				const binding = submitIntentBindingFor(eligibility);
				const args = migrationPreviewArguments({
					sourceProvider,
					sourceIdentity: sourceProvider === 'algolia' ? appId : host,
					apiKey,
					sourceName,
					targetIndex: eligibilityTargetName,
					mode
				});
				if (binding === null) return null;
				if (args === null) {
					markMigrationPreviewError(previewState, binding, 'source_provider_unsupported');
					return null;
				}
				return {
					arguments: args,
					binding,
					redactions: [
						sourceProvider === 'algolia' ? appId : host,
						apiKey,
						eligibility.eligibilityToken
					]
				};
			}
		});
	}
	async function submitImport(): Promise<void> {
		if (
			activeSubmit ||
			startsDisabled ||
			!currentPreviewSatisfied ||
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
		if (intentBinding === null || (previewSupported && !previewAttemptMatches(intentBinding))) {
			return;
		}
		const idempotencyKey = idempotencyKeyFor(intentBinding);
		const request: CreateMigrationImportJobRequest =
			sourceProvider === 'algolia'
				? {
						mode,
						appId,
						apiKey,
						sourceName,
						target: { eligibilityToken: eligibility.eligibilityToken }
					}
				: {
						mode,
						host,
						apiKey,
						sourceName,
						target: { eligibilityToken: eligibility.eligibilityToken }
					};
		activeSubmit = true;
		submitError = null;
		try {
			const job = await createMigrationJob(client, sourceProvider, request, idempotencyKey);
			successfulSubmitIntentBinding = intentBinding;
			// Source credentials are no longer needed after the job exists. Clear
			// them even when this component is embedded without a navigation callback.
			clearVolatileConnection();
			if (onImportCreated !== undefined) {
				await tick();
				onImportCreated(migrationCreateSuccessIntent(job));
			}
		} catch (error) {
			submitError = toErrorMessage(error, [
				sourceProvider === 'algolia' ? appId : host,
				apiKey,
				eligibility.eligibilityToken
			]);
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
		const requestSourceProvider = sourceProvider;
		if (
			startsDisabled ||
			requestProviderEligibilityBinding === null ||
			(activeDiscoveryRequest?.providerEligibilityBinding === requestProviderEligibilityBinding &&
				activeDiscoveryRequest.sourceProvider === requestSourceProvider)
		) {
			return;
		}
		// Pin credentials because inputs remain editable while discovery is in flight.
		const requestIdentity = sourceIdentity;
		const requestApiKey = apiKey;
		const requestCredentialRevision = credentialRevision;
		const requestApiKeyFingerprint = sourceCredentialFingerprint(requestApiKey);
		const requestId = nextDiscoveryRequestId + 1;
		nextDiscoveryRequestId = requestId;
		activeDiscoveryRequest = {
			id: requestId,
			providerEligibilityBinding: requestProviderEligibilityBinding,
			sourceProvider: requestSourceProvider
		};
		discoveryError = null;
		try {
			const credentials = {
				...migrationSourceCredentials(requestSourceProvider, requestIdentity, requestApiKey),
				...(cursor === null ? {} : { cursor })
			};
			const [page, apiKeyFingerprint] = await Promise.all([
				listMigrationSources(client, requestSourceProvider, credentials),
				requestApiKeyFingerprint
			]);
			if (
				currentProviderBinding !== requestProviderEligibilityBinding ||
				sourceProvider !== requestSourceProvider
			) {
				return;
			}
			// A first page replaces; a cursor page appends to what is already shown.
			sources = cursor === null ? page.items : [...sources, ...page.items];
			if (cursor === null) {
				clearSourceSelection();
				// A filter typed against the previous application would hide every row
				// of the new one and read as an empty account.
				searchTerm = '';
				connectedSourceIdentity = requestIdentity;
				connectedApiKeyFingerprint = apiKeyFingerprint;
				liveApiKeyFingerprint =
					credentialRevision === requestCredentialRevision &&
					liveCredentialsMatch(requestSourceProvider, requestIdentity, requestApiKey)
						? apiKeyFingerprint
						: null;
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
				!liveCredentialsMatch(requestSourceProvider, requestIdentity, requestApiKey)
			) {
				return;
			}
			// Fail closed and restart at page one; a failed cursor page cannot
			// become the apparent beginning of a partially loaded catalog.
			discoveryError = toErrorMessage(error, [requestIdentity, requestApiKey]);
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
				name={replaceDestination.name ?? ''}
				region={replaceDestination.region}
			/>
		{/if}

		<MigrationSourceConnection
			{sourceProvider}
			bind:appId
			bind:host
			bind:apiKey
			state={{
				startsDisabled,
				canStartReconnect,
				isDiscovering,
				canDiscover,
				admissionPresentation,
				discoveryError,
				showLoading: isDiscovering,
				showCredentialsChanged: credentialsChanged && !isDiscovering,
				showEmpty: hasDiscovered && !isDiscovering && !credentialsChanged
			}}
			actions={{
				onProviderChange: selectSourceProvider,
				onCredentialsChange: handleCredentialsChange,
				onConnect: handleConnectAction,
				onRetry: () => loadSourcePage(null)
			}}
		/>
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
				{#key selectedSourceName}
					<MigrationCreateDestination
						destination={{
							sourceName: selectedSourceName,
							name: destinationName,
							error: destinationError,
							replace: replaceDestination
						}}
						eligibility={{
							canCheck: canCheckTargetEligibility,
							checking: isCheckingTargetEligibility,
							error: targetEligibilityError,
							current: currentTargetEligibility
						}}
						preview={{
							result: currentPreviewResult,
							warnings: previewWarningPresentation,
							error: currentPreviewError,
							loading: isPreviewing,
							satisfied: currentPreviewSatisfied,
							supported: previewSupported
						}}
						review={{
							mode: migrationMode,
							admission: admissionPresentation,
							submitError,
							submitDisabled: startImportDisabled,
							submitting: activeSubmit,
							submitLabel: previewWarnsImportMayFail ? 'Start import anyway' : 'Start import'
						}}
						bind:confirmationName={replaceConfirmation}
						actions={{
							onDestinationInput: handleDestinationInput,
							onCheck: () => void refreshTargetEligibility(),
							onPreview: () => void runPreview(),
							onSubmit: () => void submitImport()
						}}
					/>
				{/key}
			{/if}
		</section>
	{/if}
</div>
