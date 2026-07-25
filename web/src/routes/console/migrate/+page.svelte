<script lang="ts">
	import { applyAction, deserialize } from '$app/forms';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { ActionResult } from '@sveltejs/kit';
	import { onMount } from 'svelte';
	import { DEFAULT_INTERNAL_REGIONS, SUPPORT_EMAIL } from '$lib/format';
	import type {
		AlgoliaDestinationEligibilityRequest,
		AlgoliaDestinationEligibilityResponse,
		AlgoliaMigrationAvailabilityResponse,
		AlgoliaSourceListResponse,
		CreateAlgoliaImportJobRequest,
		PublicAlgoliaImportJob,
		PublicAlgoliaImportJobPage
	} from '$lib/api/types';
	import MigrationCreateFlow from '$lib/components/migration/MigrationCreateFlow.svelte';
	import RecentImports from '$lib/components/migration/RecentImports.svelte';
	import {
		defaultProviderEligibility,
		type ProviderEligibilityState
	} from '$lib/components/migration/provider_eligibility';
	import type { MigrationCreateSuccessIntent } from '$lib/components/migration/create_success_intent';

	const RECENT_IMPORTS_PAGE_SIZE = 10;
	const RECENT_IMPORTS_FAILED = 'Recent imports could not be loaded';

	let { data } = $props<{
		data: {
			availability: AlgoliaMigrationAvailabilityResponse;
			recentImports: { page: PublicAlgoliaImportJobPage | null; error: string | null };
		};
	}>();

	const availability = $derived(data.availability);
	const defaultMigrationRegion = DEFAULT_INTERNAL_REGIONS[0]?.id ?? 'us-east-1';
	let providerEligibility = $state<ProviderEligibilityState>(defaultProviderEligibility());

	// The SSR load owns the first recent-import page; browser retry/load-more go
	// back through the single server-only recentImports action, never a browser
	// ApiClient. A list failure never hides the create flow. These seed once from
	// the SSR payload and are then owned locally by the pagination handlers.
	// svelte-ignore state_referenced_locally
	let recentImportsPage = $state<PublicAlgoliaImportJobPage | null>(
		data.recentImports?.page ?? null
	);
	// svelte-ignore state_referenced_locally
	let recentImportsError = $state<string | null>(data.recentImports?.error ?? null);
	let recentImportsLoading = $state(false);

	$effect(() => {
		recentImportsPage = data.recentImports?.page ?? null;
		recentImportsError = data.recentImports?.error ?? null;
		recentImportsLoading = false;
	});

	function buildActionPayload(payload: unknown, idempotencyKey?: string): FormData {
		const formData = new FormData();
		formData.set('payload', JSON.stringify(payload));
		if (idempotencyKey !== undefined) {
			formData.set('idempotencyKey', idempotencyKey);
		}
		return formData;
	}

	function actionFailureMessage(result: ActionResult): string {
		const data = result.type === 'failure' ? result.data : null;
		const error = data && typeof data.error === 'string' ? data.error.trim() : '';
		return error || 'Algolia migration request failed';
	}

	async function postAction(actionName: string, body: FormData): Promise<ActionResult> {
		const response = await fetch(`?/${actionName}`, {
			method: 'POST',
			headers: { 'x-sveltekit-action': 'true' },
			body
		});
		return deserialize(await response.text()) as ActionResult;
	}

	async function resolveActionResult<T>(result: ActionResult, resultKey: string): Promise<T> {
		if (result.type === 'success') {
			return (result.data as Record<string, T>)[resultKey];
		}
		await applyAction(result);
		throw new Error(actionFailureMessage(result));
	}

	async function submitMigrationAction<T>(
		actionName: string,
		payload: unknown,
		resultKey: string,
		idempotencyKey?: string
	): Promise<T> {
		const result = await postAction(actionName, buildActionPayload(payload, idempotencyKey));
		return resolveActionResult<T>(result, resultKey);
	}

	// A null cursor reloads the first page and replaces rows; a non-null cursor
	// (retry-after-error or load-more) appends the next page onto the existing
	// rows. Both paths keep pagination in this single route owner.
	async function loadRecentImportsPage(cursor: string | null): Promise<void> {
		if (recentImportsLoading) return;
		recentImportsLoading = true;
		recentImportsError = null;
		try {
			const body = new FormData();
			if (cursor !== null) body.set('cursor', cursor);
			body.set('limit', String(RECENT_IMPORTS_PAGE_SIZE));
			const result = await postAction('recentImports', body);
			const nextPage = await resolveActionResult<PublicAlgoliaImportJobPage>(
				result,
				'recentImports'
			);
			recentImportsPage = cursor === null ? nextPage : mergeRecentImports(nextPage);
		} catch (error) {
			recentImportsError =
				error instanceof Error && error.message ? error.message : RECENT_IMPORTS_FAILED;
		} finally {
			recentImportsLoading = false;
		}
	}

	function mergeRecentImports(nextPage: PublicAlgoliaImportJobPage): PublicAlgoliaImportJobPage {
		return {
			jobs: [...(recentImportsPage?.jobs ?? []), ...nextPage.jobs],
			nextCursor: nextPage.nextCursor
		};
	}

	function handleRecentImportsRetry(cursor: string | null): void {
		void loadRecentImportsPage(cursor);
	}

	function handleRecentImportsLoadMore(cursor: string): void {
		void loadRecentImportsPage(cursor);
	}

	const migrationClient = {
		listAlgoliaSourceIndexes: (request) =>
			submitMigrationAction<AlgoliaSourceListResponse>(
				'listSourceIndexes',
				request,
				'sourceIndexes'
			),
		checkAlgoliaDestinationEligibility: (request) =>
			submitMigrationAction<AlgoliaDestinationEligibilityResponse>(
				'checkDestinationEligibility',
				request,
				'targetEligibility'
			),
		createAlgoliaImportJob: (request, idempotencyKey) =>
			submitMigrationAction<PublicAlgoliaImportJob>(
				'createImportJob',
				request,
				'job',
				idempotencyKey
			)
	} satisfies {
		listAlgoliaSourceIndexes: (request: {
			appId: string;
			apiKey: string;
			cursor?: string | null;
		}) => Promise<AlgoliaSourceListResponse>;
		checkAlgoliaDestinationEligibility: (
			request: AlgoliaDestinationEligibilityRequest
		) => Promise<AlgoliaDestinationEligibilityResponse>;
		createAlgoliaImportJob: (
			request: CreateAlgoliaImportJobRequest,
			idempotencyKey: string
		) => Promise<PublicAlgoliaImportJob>;
	};

	async function loadProviderEligibility(): Promise<void> {
		try {
			providerEligibility = await submitMigrationAction<AlgoliaDestinationEligibilityResponse>(
				'providerEligibility',
				{ region: defaultMigrationRegion },
				'providerEligibility'
			);
		} catch (error) {
			providerEligibility = {
				status: 'unsupported',
				message: error instanceof Error ? error.message : 'Algolia migration request failed'
			};
		}
	}

	function handleImportCreated(intent: MigrationCreateSuccessIntent): void {
		void goto(resolve(intent.href));
	}

	onMount(() => {
		if (availability.available) {
			void loadProviderEligibility();
		}
	});
</script>

<svelte:head>
	<title>Migrate from Algolia</title>
</svelte:head>

<div class="space-y-6">
	<header class="space-y-2">
		<h2 class="text-xl font-semibold text-flapjack-ink">Migrate from Algolia</h2>
		<p class="max-w-3xl text-sm leading-6 text-flapjack-ink/70">
			{#if availability.available}
				Local activation is wired and the migration surface can report live capability state.
			{:else}
				Direct imports from Algolia are paused while we replace the importer with a safer migration
				path.
			{/if}
		</p>
	</header>

	{#if availability.available}
		<section
			data-testid="migration-available"
			class="rounded-md border border-emerald-200 bg-emerald-50 p-5"
			aria-labelledby="migration-available-title"
		>
			<div class="space-y-3">
				<p id="migration-available-title" class="text-base font-semibold text-flapjack-ink">
					Algolia migration is available
				</p>
				<p class="text-sm leading-6 text-flapjack-ink/75">
					{availability.message}
				</p>
				<MigrationCreateFlow
					client={migrationClient}
					{providerEligibility}
					capabilities={availability.capabilities}
					onImportCreated={handleImportCreated}
				/>
				<RecentImports
					page={recentImportsPage}
					loading={recentImportsLoading}
					error={recentImportsError}
					onRetry={handleRecentImportsRetry}
					onLoadMore={handleRecentImportsLoadMore}
				/>
			</div>
		</section>
	{:else}
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
	{/if}
</div>
