<script lang="ts">
	import { resolve } from '$app/paths';
	import { formatDate, formatDateTime, formatNumber } from '$lib/format';
	import type {
		AlgoliaMigrationCapabilities,
		PublicAlgoliaImportJob,
		ResumeAlgoliaImportJobRequest
	} from '$lib/api/types';
	import {
		algoliaImportCompatibilityWarning,
		algoliaImportIndexHref,
		algoliaImportSummaryRows,
		describeAlgoliaImportAdmission,
		describeAlgoliaImportError,
		describeAlgoliaImportJobActions,
		describeAlgoliaImportPublicationDisposition,
		describeAlgoliaImportStatus,
		type AlgoliaImportAdmission
	} from './job_presentation';

	const CANCEL_CONFIRM_COPY =
		'Cancel this import? The import stops, partially-copied staging work is discarded, and the existing destination index is left exactly as it is.';

	let {
		job,
		reloading = false,
		admission = { admitted: true },
		capabilities = undefined,
		onCancelIntent = undefined,
		onResumeIntent = undefined
	}: {
		job: PublicAlgoliaImportJob;
		reloading?: boolean;
		admission?: AlgoliaImportAdmission;
		capabilities?: AlgoliaMigrationCapabilities;
		onCancelIntent?: (() => void) | undefined;
		onResumeIntent?: ((request: ResumeAlgoliaImportJobRequest) => void) | undefined;
	} = $props();

	const status = $derived(describeAlgoliaImportStatus(job.status));
	const summaryRows = $derived(algoliaImportSummaryRows(job));
	const disposition = $derived(describeAlgoliaImportPublicationDisposition(job));
	const failureCopy = $derived(describeAlgoliaImportError(job.error));
	const actions = $derived(describeAlgoliaImportJobActions(job, admission, capabilities));
	const admissionPresentation = $derived(describeAlgoliaImportAdmission(admission));
	const warningSummary = $derived(algoliaImportCompatibilityWarning(job));
	const heading = $derived(`${job.source.name} import`);
	const canEmitCancel = $derived(actions.canCancel && onCancelIntent !== undefined);
	const canEmitResume = $derived(actions.canResume && onResumeIntent !== undefined);
	const jobActionToken = $derived(
		[job.id, job.status, job.updatedAt, job.cancelRequestedAt ?? '', String(job.resumeCount)].join(
			'\u0000'
		)
	);
	// The engine-authored resume window is shown as an absolute instant so the
	// customer reads the same deadline regardless of their local timezone. A
	// missing or unparseable deadline renders nothing rather than a placeholder.
	const resumeDeadline = $derived(
		job.resumeDeadline === null ? null : normalizeDeadline(formatDateTime(job.resumeDeadline))
	);

	function normalizeDeadline(formatted: string): string | null {
		return formatted === '—' ? null : formatted;
	}
	let cancelIntentSent = $state(false);
	let resumeIntentSent = $state(false);
	let resumeApiKey = $state('');
	let intentJobId = $state<string | null>(null);
	let pendingActionToken = $state<string | null>(null);
	let pendingActionSawReload = $state(false);
	const canSubmitResume = $derived(
		canEmitResume && resumeApiKey.trim() !== '' && !reloading && !resumeIntentSent
	);

	function resetPendingAction(): void {
		cancelIntentSent = false;
		resumeIntentSent = false;
		pendingActionToken = null;
		pendingActionSawReload = false;
	}

	$effect(() => {
		if (intentJobId === null) {
			intentJobId = job.id;
			return;
		}
		if (job.id === intentJobId) {
			if (pendingActionToken === null) {
				return;
			}
			if (jobActionToken !== pendingActionToken) {
				resetPendingAction();
				return;
			}
			if (reloading) {
				pendingActionSawReload = true;
				return;
			}
			if (pendingActionSawReload) {
				resetPendingAction();
			}
			return;
		}
		intentJobId = job.id;
		resetPendingAction();
		resumeApiKey = '';
	});

	function requestCancel(): void {
		if (cancelIntentSent || reloading || !canEmitCancel) {
			return;
		}
		if (!window.confirm(CANCEL_CONFIRM_COPY)) {
			return;
		}
		cancelIntentSent = true;
		pendingActionToken = jobActionToken;
		pendingActionSawReload = false;
		onCancelIntent?.();
	}

	function requestResume(): void {
		if (!canSubmitResume) {
			return;
		}
		const request = { apiKey: resumeApiKey };
		resumeIntentSent = true;
		pendingActionToken = jobActionToken;
		pendingActionSawReload = false;
		resumeApiKey = '';
		onResumeIntent?.(request);
	}
</script>

<section class="space-y-6" data-testid="migration-job-detail" aria-labelledby="migration-job-title">
	<header class="space-y-2">
		<h3 id="migration-job-title" class="text-lg font-semibold text-flapjack-ink">{heading}</h3>
		<p data-testid="migration-job-status" class="text-sm font-medium text-flapjack-ink">
			{status.label}
		</p>
		<p data-testid="migration-job-phase" class="text-sm text-flapjack-ink/70">{status.phase}</p>
		{#if reloading}
			<p data-testid="migration-job-reloading" class="text-sm text-flapjack-ink/70" role="status">
				Refreshing status
			</p>
		{/if}
		{#if status.running}
			<p data-testid="migration-job-safe-reload" class="text-sm text-flapjack-ink/70">
				You can leave or reload this page without stopping the import.
			</p>
		{/if}
	</header>

	<section class="grid gap-3 sm:grid-cols-3" aria-label="Import fields">
		<div>
			<p class="text-xs font-medium uppercase text-flapjack-ink/60">Source</p>
			<p data-testid="migration-job-source" class="text-sm text-flapjack-ink">{job.source.name}</p>
		</div>
		<div>
			<p class="text-xs font-medium uppercase text-flapjack-ink/60">Destination</p>
			<p data-testid="migration-job-destination" class="text-sm text-flapjack-ink">
				{job.destination.target}
			</p>
		</div>
		<div>
			<p class="text-xs font-medium uppercase text-flapjack-ink/60">Updated</p>
			<p data-testid="migration-job-updated" class="text-sm text-flapjack-ink">
				{formatDate(job.updatedAt)}
			</p>
		</div>
	</section>

	<section class="space-y-2" aria-label="Import summary">
		{#each summaryRows as row (row.label)}
			<div
				data-testid={`migration-summary-${row.label.toLowerCase()}`}
				class="rounded border border-flapjack-ink/20 p-3 text-sm text-flapjack-ink"
			>
				<span class="font-medium">{row.label}</span>:
				{formatNumber(row.imported)} imported · {formatNumber(row.expected)} expected · {formatNumber(
					row.rejected
				)}
				rejected
			</div>
		{/each}
	</section>

	{#if warningSummary}
		<p
			data-testid="migration-job-warning-summary"
			class="rounded border border-flapjack-yellow/50 p-3 text-sm text-flapjack-ink"
		>
			{warningSummary}
		</p>
	{/if}

	<p data-testid="migration-job-disposition" class="text-sm text-flapjack-ink/75">
		{disposition.message}
	</p>

	{#if failureCopy}
		<p
			data-testid="migration-job-error"
			class="rounded border border-flapjack-plum/40 p-3 text-sm text-flapjack-plum"
		>
			{failureCopy}
		</p>
	{/if}

	{#if actions.canTestSearch || actions.canViewIndex}
		<div class="flex flex-wrap gap-2">
			{#if actions.canTestSearch}
				<!-- eslint-disable svelte/no-navigation-without-resolve -- the typed base route is resolved before appending the static search-tab query that resolve() rejects -->
				<a
					class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white"
					href={resolve(algoliaImportIndexHref(job.destination.target)) + '?tab=search'}
				>
					Test search
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			{/if}
			{#if actions.canViewIndex}
				<a
					class="rounded border border-flapjack-ink/30 px-4 py-2 text-sm font-medium"
					href={resolve(algoliaImportIndexHref(job.destination.target))}
				>
					View index
				</a>
			{/if}
		</div>
	{/if}

	{#if canEmitCancel}
		<div class="flex flex-wrap gap-2" data-testid="migration-job-capability-actions">
			<button
				type="button"
				class="rounded border border-flapjack-plum/40 px-4 py-2 text-sm font-medium text-flapjack-plum disabled:opacity-50"
				disabled={reloading || cancelIntentSent}
				onclick={requestCancel}
			>
				Cancel import
			</button>
		</div>
	{/if}

	{#if actions.canStartNewImport}
		<a
			class="inline-flex w-fit rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white"
			href={resolve('/console/migrate')}
		>
			Start a new import
		</a>
	{/if}

	{#if actions.retryCopy}
		<section
			data-testid="migration-job-retry-panel"
			class="space-y-3 rounded border border-flapjack-ink/20 p-4"
			aria-labelledby="migration-job-retry-title"
		>
			{#if admissionPresentation.disablesStarts}
				<div data-testid="migration-job-admission">
					<p id="migration-job-retry-title" class="text-sm font-semibold text-flapjack-ink">
						{admissionPresentation.title}
					</p>
					<p class="text-sm text-flapjack-ink/70">{admissionPresentation.message}</p>
				</div>
			{:else}
				<p id="migration-job-retry-title" class="text-sm font-semibold text-flapjack-ink">
					Reconnect before retrying
				</p>
			{/if}
			<p data-testid="migration-job-retry-policy" class="text-sm text-flapjack-ink/70">
				{actions.retryCopy}
			</p>
			{#if actions.canResume && resumeDeadline}
				<p data-testid="migration-job-resume-deadline" class="text-sm text-flapjack-ink/70">
					Resume before {resumeDeadline}.
					{#if job.resumeProvenance}
						<span class="block text-flapjack-ink/60">{job.resumeProvenance}</span>
					{/if}
				</p>
			{/if}
			<label class="block text-sm font-medium text-flapjack-ink/80" for="migration-retry-api-key">
				Algolia API key
			</label>
			<input
				id="migration-retry-api-key"
				type="password"
				bind:value={resumeApiKey}
				autocomplete="off"
				class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
			/>
			{#if canEmitResume}
				<button
					type="button"
					class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
					disabled={!canSubmitResume}
					onclick={requestResume}
				>
					Resume import
				</button>
			{:else}
				<button
					type="button"
					class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
					disabled={!actions.canEnterRetryKey}
				>
					Reconnect and retry
				</button>
			{/if}
		</section>
	{/if}
</section>
