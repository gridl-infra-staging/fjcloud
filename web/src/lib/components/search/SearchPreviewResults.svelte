<script lang="ts">
	import { enhance } from '$app/forms';
	import { tick } from 'svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import DocumentCard from '../DocumentCard.svelte';
	import { trackDeleteDocumentResult } from './document_delete_feedback';
	import { toast } from '$lib/toast';
	import { createMerchandisingRule } from '$lib/utils/merchandising';

	type SearchHit = Record<string, unknown>;

	let {
		nbHits = 0,
		processingTimeMS = 0,
		hits = [],
		page = 1,
		totalPages = 1,
		loading = false,
		titleField = null,
		subtitleField = null,
		imageField = null,
		tagsField = null,
		showJsonView = false,
		query = '',
		hitsPerPage = 20,
		indexName = '',
		merchMode = false,
		pinnedPositions = new Map(),
		hasActiveFilters = false,
		onPin = () => {},
		onPromote = () => {},
		onBury = () => {},
		onPageChange = () => {},
		onHitsPerPageChange = () => {},
		onClearFilters = () => {},
		onHitClick = () => {}
	}: {
		nbHits?: number;
		processingTimeMS?: number;
		hits?: SearchHit[];
		page?: number;
		totalPages?: number;
		loading?: boolean;
		titleField?: string | null;
		subtitleField?: string | null;
		imageField?: string | null;
		tagsField?: string | null;
		showJsonView?: boolean;
		query?: string;
		hitsPerPage?: number;
		indexName?: string;
		merchMode?: boolean;
		pinnedPositions?: Map<string, number>;
		hasActiveFilters?: boolean;
		onPin?: (objectID: string, position: number) => void;
		onPromote?: (objectID: string) => void;
		onBury?: (objectID: string) => void;
		onPageChange?: (nextPage: number) => void;
		onHitsPerPageChange?: (nextHitsPerPage: number) => void;
		onClearFilters?: () => void;
		onHitClick?: (hit: SearchHit, position: number) => void;
	} = $props();

	let pendingDeleteObjectId = $state<string | null>(null);
	let pendingDeleteForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteTrigger = $state<HTMLElement | null>(null);
	let showDeleteConfirmDialog = $state(false);

	let merchRuleObjectID = $state('');
	let merchRuleJson = $state('');
	let merchRuleForm = $state<HTMLFormElement | null>(null);

	const previousDisabled = $derived(page <= 1 || loading);
	const nextDisabled = $derived(page >= totalPages || loading);
	const pageNumbers = $derived.by(() => {
		const pageCount = Math.max(1, totalPages);
		const visibleCount = Math.min(pageCount, 7);
		const firstPage = Math.min(
			Math.max(1, page - Math.floor(visibleCount / 2)),
			pageCount - visibleCount + 1
		);
		return Array.from({ length: visibleCount }, (_, index) => firstPage + index);
	});

	function objectIdForDelete(hit: SearchHit): string | null {
		return typeof hit.objectID === 'string' && hit.objectID.trim().length > 0 ? hit.objectID : null;
	}

	function openDeleteConfirmDialog(
		objectId: string,
		form: HTMLFormElement,
		trigger: HTMLElement
	): void {
		pendingDeleteObjectId = objectId;
		pendingDeleteForm = form;
		pendingDeleteTrigger = trigger;
		showDeleteConfirmDialog = true;
	}

	function closeDeleteConfirmDialog(): void {
		showDeleteConfirmDialog = false;
		pendingDeleteObjectId = null;
		pendingDeleteForm = null;
		pendingDeleteTrigger = null;
	}

	function confirmDeleteDocument(): void {
		pendingDeleteForm?.requestSubmit();
		closeDeleteConfirmDialog();
	}

	async function submitMerchRule(objectID: string, ruleJson: string): Promise<void> {
		merchRuleObjectID = objectID;
		merchRuleJson = ruleJson;
		await tick();
		merchRuleForm?.requestSubmit();
	}

	function handlePin(objectID: string, position: number): void {
		const rule = createMerchandisingRule({ query, pins: [{ objectID, position }], hides: [] });
		void submitMerchRule(rule.objectID, JSON.stringify(rule));
	}

	function handlePromote(objectID: string): void {
		const rule = createMerchandisingRule({ query, pins: [{ objectID, position: 0 }], hides: [] });
		void submitMerchRule(rule.objectID, JSON.stringify(rule));
	}

	function handleBury(objectID: string): void {
		const rule = createMerchandisingRule({ query, pins: [], hides: [{ objectID }] });
		void submitMerchRule(rule.objectID, JSON.stringify(rule));
	}

	function handleMerchRuleSave() {
		return async ({ result }: { result: { type: string } }) => {
			if (result.type === 'success') {
				toast.success('Rule created');
			} else {
				toast.error('Failed to create rule');
			}
		};
	}
</script>

<section class="space-y-3" data-testid="search-preview-results">
	<div class="flex flex-wrap items-center justify-between gap-3">
		<p class="text-sm text-flapjack-ink">{nbHits} hits in {processingTimeMS}ms</p>
		<div class="flex flex-wrap items-center gap-2">
			<label class="flex items-center gap-2 text-xs text-flapjack-ink">
				Results per page
				<select
					aria-label="Results per page"
					class="rounded border border-flapjack-ink/20 bg-white px-2 py-1"
					value={hitsPerPage}
					disabled={loading}
					onchange={(event) =>
						onHitsPerPageChange(Number((event.currentTarget as HTMLSelectElement).value))}
				>
					{#each Array.from(new Set( [10, 20, 50, hitsPerPage] )).sort((a, b) => a - b) as size (size)}
						<option value={size}>{size}</option>
					{/each}
				</select>
			</label>
			<button
				type="button"
				class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs disabled:opacity-50"
				aria-label="Previous page"
				disabled={previousDisabled}
				onclick={() => onPageChange(page - 1)}
			>
				Prev
			</button>
			{#each pageNumbers as pageNumber (pageNumber)}
				<button
					type="button"
					class="min-w-8 rounded border border-flapjack-ink/20 px-2 py-1 text-xs disabled:opacity-50"
					aria-label={`Page ${pageNumber}`}
					aria-current={pageNumber === page ? 'page' : undefined}
					disabled={loading || pageNumber === page}
					onclick={() => onPageChange(pageNumber)}
				>
					{pageNumber}
				</button>
			{/each}
			<button
				type="button"
				class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs disabled:opacity-50"
				aria-label="Next page"
				disabled={nextDisabled}
				onclick={() => onPageChange(page + 1)}
			>
				Next
			</button>
		</div>
	</div>

	{#if loading && hits.length === 0}
		<div
			data-testid="search-preview-results-skeleton"
			class="rounded border border-flapjack-ink/15 bg-flapjack-cream/70 p-4 text-sm text-flapjack-ink/70"
		>
			Loading preview results...
		</div>
	{:else if hits.length === 0}
		<div class="rounded-md border border-flapjack-ink/15 p-4 text-sm text-flapjack-ink/70">
			{#if query.length > 0}
				<p class="font-medium text-flapjack-ink">No results for “{query}”.</p>
				<p class="mt-1">Try a broader query or remove a refinement.</p>
			{:else}
				<p class="font-medium text-flapjack-ink">No documents to browse yet.</p>
			{/if}
			{#if hasActiveFilters}
				<button
					type="button"
					class="mt-2 font-medium text-flapjack-rose hover:text-flapjack-plum"
					onclick={onClearFilters}>Clear filters</button
				>
			{/if}
		</div>
	{:else}
		{#if loading}
			<p class="text-xs font-medium text-flapjack-plum" role="status">Updating results…</p>
		{/if}
		<div class="space-y-2">
			{#each hits as hit, index (String(hit.objectID ?? index))}
				{@const objectId = objectIdForDelete(hit)}
				<div>
					<DocumentCard
						{hit}
						{titleField}
						{subtitleField}
						{imageField}
						{tagsField}
						{showJsonView}
						{merchMode}
						onOpenDetails={() => onHitClick(hit, index + 1)}
						pinnedAt={pinnedPositions.get(String(hit.objectID)) ?? null}
						onPin={merchMode ? handlePin : onPin}
						onPromote={merchMode ? handlePromote : onPromote}
						onBury={merchMode ? handleBury : onBury}
					/>
					{#if objectId}
						<form
							method="POST"
							action="?/deleteDocument"
							use:enhance={trackDeleteDocumentResult}
							class="mt-2"
						>
							<input type="hidden" name="objectID" value={objectId} />
							<input type="hidden" name="query" value={query} />
							<input type="hidden" name="hitsPerPage" value={String(hitsPerPage)} />
							<button
								type="button"
								aria-label={`Delete document ${objectId}`}
								class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
								onclick={(event) => {
									event.stopPropagation();
									const trigger = event.currentTarget;
									if (!(trigger instanceof HTMLElement)) {
										return;
									}
									const deleteForm = trigger.closest('form');
									if (!(deleteForm instanceof HTMLFormElement)) {
										return;
									}
									openDeleteConfirmDialog(objectId, deleteForm, trigger);
								}}
							>
								Delete
							</button>
						</form>
					{/if}
				</div>
			{/each}
		</div>
	{/if}
</section>

<form
	method="POST"
	action="?/saveRule"
	use:enhance={handleMerchRuleSave}
	bind:this={merchRuleForm}
	class="hidden"
>
	<input type="hidden" name="objectID" bind:value={merchRuleObjectID} />
	<input type="hidden" name="rule" bind:value={merchRuleJson} />
</form>

<ConfirmDialog
	open={showDeleteConfirmDialog}
	mode="standard"
	dangerLevel="warn"
	title="Delete document?"
	consequences={pendingDeleteObjectId && indexName
		? `Delete document "${pendingDeleteObjectId}" from ${indexName}.`
		: 'Delete this document.'}
	rationale="This record will no longer appear in browse results."
	entityName={pendingDeleteObjectId ?? indexName}
	confirmLabel="Delete"
	cancelLabel="Cancel"
	onCancel={closeDeleteConfirmDialog}
	onConfirm={confirmDeleteDocument}
	triggerRef={pendingDeleteTrigger}
/>
