<script lang="ts">
	import { formatDate } from '$lib/format';
	import type { PublicAlgoliaImportJobPage } from '$lib/api/types';
	import { migrationJobHref } from './create_success_intent';
	import { describeAlgoliaImportStatus } from './job_presentation';

	let {
		page,
		loading = false,
		error = null,
		onRetry,
		onLoadMore
	}: {
		page: PublicAlgoliaImportJobPage | null;
		loading?: boolean;
		error?: string | null;
		onRetry: (cursor: string | null) => void;
		onLoadMore: (cursor: string) => void;
	} = $props();

	const jobs = $derived(page?.jobs ?? []);
	const nextCursor = $derived(page?.nextCursor ?? null);
	const hasRows = $derived(jobs.length > 0);
	let intentPending = $state(false);

	$effect(() => {
		if (loading) {
			intentPending = false;
		}
	});

	function requestLoadMore(): void {
		if (intentPending || loading || nextCursor === null) {
			return;
		}
		intentPending = true;
		onLoadMore(nextCursor);
	}

	function requestRetry(cursor: string | null): void {
		if (intentPending || loading) {
			return;
		}
		intentPending = true;
		onRetry(cursor);
	}
</script>

<section
	class="space-y-4"
	data-testid="migration-recent-imports"
	aria-labelledby="recent-imports-title"
>
	<div class="space-y-1">
		<h3 id="recent-imports-title" class="text-base font-semibold text-flapjack-ink">
			Recent imports
		</h3>
		<p class="text-sm text-flapjack-ink/70">
			Reopen retained imports to check status or continue recovery.
		</p>
	</div>

	{#if !hasRows}
		{#if loading}
			<p
				data-testid="migration-recent-imports-loading"
				class="text-sm text-flapjack-ink/70"
				role="status"
			>
				Loading recent imports
			</p>
		{:else if error}
			<div
				data-testid="migration-recent-imports-error"
				role="alert"
				class="space-y-3 rounded border border-flapjack-plum/40 p-4"
			>
				<p class="text-sm text-flapjack-plum">{error}</p>
				<button
					type="button"
					class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
					disabled={loading || intentPending}
					onclick={() => requestRetry(null)}
				>
					Retry recent imports
				</button>
			</div>
		{:else}
			<p data-testid="migration-recent-imports-empty" class="text-sm text-flapjack-ink/70">
				No Algolia imports yet
			</p>
		{/if}
	{:else}
		<ul class="space-y-2">
			{#each jobs as job (job.id)}
				{@const status = describeAlgoliaImportStatus(job.status)}
				<li
					data-testid={`migration-recent-import-${job.id}`}
					class="rounded border border-flapjack-ink/20 p-3"
				>
					<div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
						<div class="space-y-1">
							<p class="text-sm font-medium text-flapjack-ink">
								{job.source.name} to {job.destination.target}
							</p>
							<p class="text-xs text-flapjack-ink/70">
								{status.label} · {job.destination.region} · Updated {formatDate(job.updatedAt)}
							</p>
						</div>
						<!-- eslint-disable svelte/no-navigation-without-resolve -- this durable route stays dormant until the activation lane mounts it -->
						<a
							class="text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
							href={migrationJobHref(job.id)}
						>
							Open import {job.id}
						</a>
						<!-- eslint-enable svelte/no-navigation-without-resolve -->
					</div>
				</li>
			{/each}
		</ul>

		{#if error}
			<div
				data-testid="migration-recent-imports-error"
				role="alert"
				class="space-y-3 rounded border border-flapjack-plum/40 p-4"
			>
				<p class="text-sm text-flapjack-plum">{error}</p>
				<button
					type="button"
					class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
					disabled={loading || intentPending}
					onclick={() => requestRetry(nextCursor)}
				>
					Retry recent imports
				</button>
			</div>
		{:else if nextCursor !== null}
			<button
				type="button"
				class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
				disabled={loading || intentPending}
				onclick={requestLoadMore}
			>
				Load more imports
			</button>
		{/if}
	{/if}
</section>
