<script lang="ts">
	import { enhance } from '$app/forms';
	import type { BrowseObjectsResponse, Index } from '$lib/api/types';
	import {
		MAX_DOCUMENT_UPLOAD_BYTES,
		parseUploadFileRecords,
		type UploadFormat
	} from './documents-file-parser';
	import { buildAddObjectBatchPayload } from './documents_batch_payload';

	const DEFAULT_HITS_PER_PAGE = 20;
	const PREVIEW_LIMIT = 5;

	type Props = {
		index: Index;
		documents: BrowseObjectsResponse;
		documentsUploadSuccess: boolean;
		documentsAddSuccess: boolean;
		documentsBrowseSuccess: boolean;
		documentsDeleteSuccess: boolean;
		documentsUploadError: string;
		documentsAddError: string;
		documentsBrowseError: string;
		documentsDeleteError: string;
	};

	let {
		index,
		documents,
		documentsUploadSuccess,
		documentsAddSuccess,
		documentsBrowseSuccess,
		documentsDeleteSuccess,
		documentsUploadError,
		documentsAddError,
		documentsBrowseError,
		documentsDeleteError
	}: Props = $props();

	let selectedFileName = $state('');
	let uploadFormat = $state<UploadFormat | null>(null);
	let uploadDraftError = $state('');
	let parsedUploadRecords = $state<Record<string, unknown>[]>([]);
	let manualDocumentJson = $state(
		JSON.stringify(
			{
				objectID: '',
				title: ''
			},
			null,
			2
		)
	);
	let browseQueryDraft = $state('');
	let browseCursorDraft = $state('');
	let hitsPerPageDraft = $state(DEFAULT_HITS_PER_PAGE);

	const hasDocumentHits = $derived(documents.hits.length > 0);
	const browseQuery = $derived(documents.query ?? '');
	const browseHitsPerPage = $derived(
		documents.hitsPerPage > 0 ? documents.hitsPerPage : DEFAULT_HITS_PER_PAGE
	);
	const uploadPreviewRecords = $derived(parsedUploadRecords.slice(0, PREVIEW_LIMIT));
	const uploadBatchPayload = $derived(buildAddObjectBatchPayload(parsedUploadRecords));

	$effect(() => {
		browseQueryDraft = browseQuery;
		hitsPerPageDraft = browseHitsPerPage;
	});

	function hitObjectId(hit: Record<string, unknown>, indexAt: number): string {
		const value = hit.objectID;
		return typeof value === 'string' && value.trim().length > 0 ? value : `row-${indexAt + 1}`;
	}

	async function handleUploadFileChange(event: Event): Promise<void> {
		const input = event.currentTarget;
		if (!(input instanceof HTMLInputElement)) return;

		const file = input.files?.[0];
		parsedUploadRecords = [];
		uploadDraftError = '';
		uploadFormat = null;
		selectedFileName = '';

		if (!file) return;

		selectedFileName = file.name;
		if (file.size > MAX_DOCUMENT_UPLOAD_BYTES) {
			uploadDraftError = 'File exceeds 100MB limit';
			return;
		}

		try {
			const parsedFile = await parseUploadFileRecords(file);
			uploadFormat = parsedFile.format;
			parsedUploadRecords = parsedFile.records;
		} catch (e) {
			parsedUploadRecords = [];
			uploadDraftError = e instanceof Error ? e.message : 'Failed to parse file';
		}
	}
</script>

<div class="space-y-6" data-testid="documents-section" data-index={index.name}>
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Documents</h2>
		<p class="mb-4 text-sm text-flapjack-ink/70">
			Upload JSON or CSV records, add a single record manually, then browse and delete records with
			cursor-based navigation.
		</p>

		{#if documentsUploadSuccess}
			<div
				class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
			>
				Documents uploaded.
			</div>
		{/if}

		{#if documentsAddSuccess}
			<div
				class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
			>
				Document added.
			</div>
		{/if}

		{#if documentsBrowseSuccess}
			<div
				class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
			>
				Documents refreshed.
			</div>
		{/if}

		{#if documentsDeleteSuccess}
			<div
				class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
			>
				Document deleted.
			</div>
		{/if}

		{#if documentsUploadError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{documentsUploadError}
			</div>
		{/if}

		{#if documentsAddError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{documentsAddError}
			</div>
		{/if}

		{#if documentsBrowseError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{documentsBrowseError}
			</div>
		{/if}

		{#if documentsDeleteError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{documentsDeleteError}
			</div>
		{/if}
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Upload</h3>
		<form method="POST" action="?/uploadDocuments" use:enhance>
			<label for="documents-upload-file" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Upload JSON or CSV file</label
			>
			<input
				id="documents-upload-file"
				aria-label="Upload JSON or CSV file"
				type="file"
				accept=".json,.csv,application/json,text/csv"
				onchange={handleUploadFileChange}
				class="mb-3 block w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
			/>

			{#if selectedFileName}
				<p class="mb-1 text-sm text-flapjack-ink/70">Selected file: {selectedFileName}</p>
			{/if}
			{#if uploadFormat}
				<p class="mb-1 text-sm text-flapjack-ink/70">
					Detected format: {uploadFormat.toUpperCase()}
				</p>
			{/if}
			{#if parsedUploadRecords.length > 0}
				<p class="mb-3 text-sm text-flapjack-ink/80">
					Parsed records: {parsedUploadRecords.length}
				</p>
				<div class="mb-4 space-y-2 rounded-md border border-flapjack-ink/20 p-3">
					<p class="text-xs font-semibold uppercase tracking-wide text-flapjack-ink/60">Preview</p>
					{#each uploadPreviewRecords as record, previewIndex (`preview-${previewIndex}`)}
						<pre
							class="overflow-x-auto rounded bg-flapjack-cream/80 p-2 text-xs text-flapjack-ink/80">{JSON.stringify(
								record,
								null,
								2
							)}</pre>
					{/each}
				</div>
			{/if}
			{#if uploadDraftError}
				<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
					{uploadDraftError}
				</div>
			{/if}

			<input type="hidden" name="batch" value={uploadBatchPayload} />
			<input type="hidden" name="query" value={browseQuery} />
			<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
			<button
				type="submit"
				disabled={parsedUploadRecords.length === 0 || uploadDraftError.length > 0}
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:opacity-50"
			>
				Upload Records
			</button>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Add Manually</h3>
		<form method="POST" action="?/addDocument" use:enhance>
			<label for="manual-document-json" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Record JSON</label
			>
			<textarea
				id="manual-document-json"
				aria-label="Record JSON"
				name="document"
				bind:value={manualDocumentJson}
				rows="10"
				class="mb-3 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm"
			></textarea>
			<input type="hidden" name="query" value={browseQuery} />
			<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
			<button
				type="submit"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Add Record
			</button>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Browse & Delete</h3>
		<form
			method="POST"
			action="?/browseDocuments"
			use:enhance
			class="mb-4 grid gap-3 md:grid-cols-3"
		>
			<div>
				<label
					for="documents-browse-query"
					class="mb-1 block text-sm font-medium text-flapjack-ink/80">Browse Query</label
				>
				<input
					id="documents-browse-query"
					aria-label="Browse Query"
					name="query"
					type="text"
					bind:value={browseQueryDraft}
					placeholder="e.g. title:First"
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				/>
			</div>
			<div>
				<label
					for="documents-browse-cursor"
					class="mb-1 block text-sm font-medium text-flapjack-ink/80">Cursor</label
				>
				<input
					id="documents-browse-cursor"
					name="cursor"
					type="text"
					bind:value={browseCursorDraft}
					placeholder="Optional cursor token"
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				/>
			</div>
			<div>
				<label
					for="documents-hits-per-page"
					class="mb-1 block text-sm font-medium text-flapjack-ink/80">Hits per page</label
				>
				<input
					id="documents-hits-per-page"
					name="hitsPerPage"
					type="number"
					min="1"
					bind:value={hitsPerPageDraft}
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				/>
			</div>
			<div class="md:col-span-3">
				<button
					type="submit"
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
				>
					Browse Documents
				</button>
			</div>
		</form>

		{#if documents.cursor}
			<form method="POST" action="?/browseDocuments" use:enhance class="mb-4">
				<input type="hidden" name="query" value={browseQuery} />
				<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
				<input type="hidden" name="cursor" value={documents.cursor} />
				<button
					type="submit"
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
				>
					Load Next Page
				</button>
			</form>
			<p class="mb-4 text-xs text-flapjack-ink/60">Next cursor: {documents.cursor}</p>
		{/if}

		{#if hasDocumentHits}
			<div class="space-y-3">
				{#each documents.hits as hit, hitIndex (`${hitObjectId(hit, hitIndex)}-${hitIndex}`)}
					{@const objectId = hitObjectId(hit, hitIndex)}
					<div class="rounded-md border border-flapjack-ink/20 p-3">
						<div class="mb-2 flex items-center justify-between">
							<p class="font-mono text-sm text-flapjack-ink">{objectId}</p>
							<form method="POST" action="?/deleteDocument" use:enhance>
								<input type="hidden" name="objectID" value={objectId} />
								<input type="hidden" name="query" value={browseQuery} />
								<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
								<button
									type="submit"
									aria-label={`Delete document ${objectId}`}
									class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
								>
									Delete
								</button>
							</form>
						</div>
						<pre
							class="overflow-x-auto rounded bg-flapjack-cream/80 p-2 text-xs text-flapjack-ink/80">{JSON.stringify(
								hit,
								null,
								2
							)}</pre>
					</div>
				{/each}
			</div>
		{:else}
			<p class="text-sm text-flapjack-ink/60">No documents found</p>
		{/if}
	</div>
</div>
