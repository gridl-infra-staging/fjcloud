<script lang="ts">
	import type {
		PublicAlgoliaImportJob,
		VerifySourceMigrationResponse,
		SourceProvider
	} from '$lib/api/types';
	import {
		describeMigrationVerificationFailure,
		type MigrationVerificationFailurePresentation
	} from './job_presentation';
	import type {
		MigrationCutoverVerificationInputs,
		MigrationCutoverVerificationIntent
	} from './migration_cutover_verification_state';

	let {
		job,
		report = null,
		error = null,
		activeRequest = false,
		verifySupported = false,
		onVerifyIntent = undefined,
		onVerificationInputsChange = undefined
	}: {
		job: PublicAlgoliaImportJob;
		report?: VerifySourceMigrationResponse | null;
		error?: { code?: string | null; message?: string | null } | null;
		activeRequest?: boolean;
		// Server-published `capabilities.verify` for this job's source provider.
		// Fails closed: an absent capability hides the verification controls.
		verifySupported?: boolean;
		onVerifyIntent?:
			| ((request: MigrationCutoverVerificationIntent) => void | Promise<void>)
			| undefined;
		onVerificationInputsChange?: ((inputs: MigrationCutoverVerificationInputs) => void) | undefined;
	} = $props();

	let appId = $state('');
	let apiKey = $state('');
	let queriesText = $state('running shoes');
	let resultLimit = $state(10);

	const completedJob = $derived(
		job.status === 'completed' || job.status === 'completed_with_warnings'
	);
	const providerLabel = $derived(providerDisplayName(job.sourceProvider));
	const failure = $derived<MigrationVerificationFailurePresentation | null>(
		describeMigrationVerificationFailure(job.sourceProvider, error)
	);
	const hasReport = $derived(report !== null);

	function providerDisplayName(sourceProvider: SourceProvider): string {
		switch (sourceProvider) {
			case 'algolia':
				return 'Algolia';
			case 'meilisearch':
				return 'Meilisearch';
			case 'typesense':
				return 'Typesense';
		}
	}

	function parsedQueries(): string[] {
		return queriesText
			.split(/\r?\n/)
			.map((query) => query.trim())
			.filter((query) => query !== '');
	}

	function currentVerificationInputs(): MigrationCutoverVerificationInputs {
		return { queries: parsedQueries(), resultLimit };
	}

	function handleQueriesInput(event: Event): void {
		queriesText = (event.currentTarget as HTMLTextAreaElement).value;
		onVerificationInputsChange?.(currentVerificationInputs());
	}

	function handleResultLimitInput(event: Event): void {
		resultLimit = (event.currentTarget as HTMLInputElement).valueAsNumber;
		onVerificationInputsChange?.(currentVerificationInputs());
	}

	async function submitVerification(): Promise<void> {
		if (activeRequest) return;
		if (!onVerifyIntent) return;
		try {
			await onVerifyIntent({ appId, apiKey, ...currentVerificationInputs() });
		} finally {
			appId = '';
			apiKey = '';
		}
	}
</script>

{#if completedJob}
	<section
		class="space-y-4 rounded border border-flapjack-ink/20 p-4"
		aria-label="Cutover verification"
	>
		<header class="space-y-1">
			<h3 class="text-base font-semibold text-flapjack-ink">Cutover verification</h3>
			{#if hasReport}
				<p class="text-sm text-flapjack-ink/70">
					Review the matching result identifiers and rank movement before cutover.
				</p>
			{:else}
				<p class="text-sm text-flapjack-ink/70">
					Compare top result identifiers and rank positions before cutover. This inspection report
					is not a migration verdict, score, threshold, pass badge, or deployment approval.
				</p>
			{/if}
		</header>

		<div class="grid gap-3 sm:grid-cols-2" aria-label="Verification indexes">
			<div>
				<p class="text-xs font-medium uppercase text-flapjack-ink/75">Source index</p>
				<p data-testid="cutover-verification-source-index" class="text-sm text-flapjack-ink">
					{job.source.name}
				</p>
			</div>
			<div>
				<p class="text-xs font-medium uppercase text-flapjack-ink/75">Destination index</p>
				<p data-testid="cutover-verification-destination-index" class="text-sm text-flapjack-ink">
					{job.destination.target}
				</p>
			</div>
		</div>

		{#if verifySupported}
			<form class="space-y-3" onsubmit={(event) => event.preventDefault()}>
				<label class="block text-sm font-medium text-flapjack-ink/80" for="verify-app-id">
					Algolia Application ID
				</label>
				<input
					id="verify-app-id"
					type="text"
					bind:value={appId}
					autocomplete="off"
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
				/>

				<label class="block text-sm font-medium text-flapjack-ink/80" for="verify-api-key">
					Algolia API key
				</label>
				<input
					id="verify-api-key"
					type="password"
					bind:value={apiKey}
					autocomplete="off"
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
				/>

				<label class="block text-sm font-medium text-flapjack-ink/80" for="verify-queries">
					Queries
				</label>
				<textarea
					id="verify-queries"
					value={queriesText}
					oninput={handleQueriesInput}
					rows="3"
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
				></textarea>

				<label class="block text-sm font-medium text-flapjack-ink/80" for="verify-result-limit">
					Result limit
				</label>
				<input
					id="verify-result-limit"
					type="number"
					min="1"
					max="100"
					value={resultLimit}
					oninput={handleResultLimitInput}
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2 sm:w-40"
				/>

				<button
					type="button"
					class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
					disabled={activeRequest}
					onclick={submitVerification}
				>
					{activeRequest ? 'Running verification' : 'Run verification'}
				</button>
			</form>
		{:else}
			<p class="text-sm text-flapjack-ink/70">
				{providerLabel} verification is not supported yet for retained migration jobs.
			</p>
		{/if}

		{#if activeRequest}
			<p role="status" class="text-sm text-flapjack-ink/70">Running cutover verification</p>
		{/if}

		{#if failure}
			<p role="alert" class="rounded border border-flapjack-plum/40 p-3 text-sm text-flapjack-plum">
				{failure.message}
			</p>
		{/if}

		{#if report}
			<section class="space-y-4" aria-label="Cutover verification report">
				<p class="text-sm text-flapjack-ink/75">
					Report for {report.sourceIndex} to {report.destinationIndex}, result limit
					{report.resultLimit}. Review matching object IDs and rank movement before cutover.
				</p>
				{#each report.queries as queryReport, queryIndex (queryIndex)}
					<section
						class="space-y-3 rounded border border-flapjack-ink/20 p-3"
						aria-label={`Cutover verification query report: ${queryReport.query}`}
					>
						<h4 class="text-sm font-semibold text-flapjack-ink">{queryReport.query}</h4>
						<p class="text-sm text-flapjack-ink/75">Overlap {queryReport.overlapCount}</p>

						<div class="grid gap-3 sm:grid-cols-2">
							{@render objectIdList(
								'Source-only object IDs',
								queryReport.query,
								queryReport.sourceOnly
							)}
							{@render objectIdList(
								'Destination-only object IDs',
								queryReport.query,
								queryReport.destinationOnly
							)}
						</div>

						<table
							class="w-full table-auto text-left text-sm"
							aria-label={`Hit rank comparison: ${queryReport.query}`}
						>
							<thead>
								<tr class="border-b border-flapjack-ink/20">
									<th class="py-2 pr-2 font-medium">Object ID</th>
									<th class="py-2 pr-2 font-medium">Source rank</th>
									<th class="py-2 pr-2 font-medium">Destination rank</th>
									<th class="py-2 font-medium">Rank delta</th>
								</tr>
							</thead>
							<tbody>
								{#each queryReport.hits as hit (hit.objectID)}
									<tr class="border-b border-flapjack-ink/10">
										<td class="py-2 pr-2 break-all">{hit.objectID}</td>
										<td class="py-2 pr-2">{hit.sourceRank}</td>
										<td class="py-2 pr-2">{hit.destinationRank}</td>
										<td class="py-2">{hit.rankDelta}</td>
									</tr>
								{/each}
							</tbody>
						</table>
					</section>
				{/each}
			</section>
		{/if}
	</section>
{/if}

{#snippet objectIdList(title: string, query: string, items: string[])}
	<section>
		<p class="text-sm font-medium text-flapjack-ink">{title}</p>
		<ul class="mt-1 space-y-1 text-sm text-flapjack-ink/75" aria-label={`${title}: ${query}`}>
			{#if items.length === 0}
				<li>None</li>
			{:else}
				{#each items as item (item)}
					<li class="break-all">{item}</li>
				{/each}
			{/if}
		</ul>
	</section>
{/snippet}
