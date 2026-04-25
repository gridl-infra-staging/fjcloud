<script lang="ts">
	import { enhance } from '$app/forms';
	import type { BrowseObjectsResponse, Index } from '$lib/api/types';
	import {
		MAX_DOCUMENT_UPLOAD_BYTES,
		parseUploadFileRecords,
		type UploadFormat
	} from './documents-file-parser';

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
	const uploadBatchPayload = $derived(
		JSON.stringify({
			requests: parsedUploadRecords.map((record) => ({
				action: 'addObject',
				body: record
			}))
		})
	);

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
		<h2 class="mb-2 text-lg font-medium text-gray-900">Documents</h2>
		<p class="mb-4 text-sm text-gray-600">
			Upload JSON or CSV records, add a single record manually, then browse and delete records with
			cursor-based navigation.
		</p>

		{#if documentsUploadSuccess}
			<div class="mb-3 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
				Documents uploaded.
			</div>
		{/if}

		{#if documentsAddSuccess}
			<div class="mb-3 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
				Document added.
			</div>
		{/if}

		{#if documentsBrowseSuccess}
			<div class="mb-3 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
				Documents refreshed.
			</div>
		{/if}

		{#if documentsDeleteSuccess}
			<div class="mb-3 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
				Document deleted.
			</div>
		{/if}

		{#if documentsUploadError}
			<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">{documentsUploadError}</div>
		{/if}

		{#if documentsAddError}
			<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">{documentsAddError}</div>
		{/if}

		{#if documentsBrowseError}
			<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">{documentsBrowseError}</div>
		{/if}

		{#if documentsDeleteError}
			<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">{documentsDeleteError}</div>
		{/if}
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-gray-900">Upload</h3>
		<form method="POST" action="?/uploadDocuments" use:enhance>
			<label for="documents-upload-file" class="mb-2 block text-sm font-medium text-gray-700"
				>Upload JSON or CSV file</label
			>
			<input
				id="documents-upload-file"
				aria-label="Upload JSON or CSV file"
				type="file"
				accept=".json,.csv,application/json,text/csv"
				onchange={handleUploadFileChange}
				class="mb-3 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
			/>

			{#if selectedFileName}
				<p class="mb-1 text-sm text-gray-600">Selected file: {selectedFileName}</p>
			{/if}
			{#if uploadFormat}
				<p class="mb-1 text-sm text-gray-600">Detected format: {uploadFormat.toUpperCase()}</p>
			{/if}
			{#if parsedUploadRecords.length > 0}
				<p class="mb-3 text-sm text-gray-700">Parsed records: {parsedUploadRecords.length}</p>
				<div class="mb-4 space-y-2 rounded-md border border-gray-200 p-3">
					<p class="text-xs font-semibold uppercase tracking-wide text-gray-500">Preview</p>
					{#each uploadPreviewRecords as record, previewIndex (`preview-${previewIndex}`)}
						<pre
							class="overflow-x-auto rounded bg-gray-50 p-2 text-xs text-gray-700">{JSON.stringify(
								record,
								null,
								2
							)}</pre>
					{/each}
				</div>
			{/if}
			{#if uploadDraftError}
				<div class="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-700">{uploadDraftError}</div>
			{/if}

			<input type="hidden" name="batch" value={uploadBatchPayload} />
			<input type="hidden" name="query" value={browseQuery} />
			<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
			<button
				type="submit"
				disabled={parsedUploadRecords.length === 0 || uploadDraftError.length > 0}
				class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
			>
				Upload Records
			</button>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-gray-900">Add Manually</h3>
		<form method="POST" action="?/addDocument" use:enhance>
			<label for="manual-document-json" class="mb-2 block text-sm font-medium text-gray-700"
				>Record JSON</label
			>
			<textarea
				id="manual-document-json"
				aria-label="Record JSON"
				name="document"
				bind:value={manualDocumentJson}
				rows="10"
				class="mb-3 w-full rounded-md border border-gray-300 p-3 font-mono text-sm"
			></textarea>
			<input type="hidden" name="query" value={browseQuery} />
			<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
			<button
				type="submit"
				class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Add Record
			</button>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-gray-900">Browse & Delete</h3>
		<form
			method="POST"
			action="?/browseDocuments"
			use:enhance
			class="mb-4 grid gap-3 md:grid-cols-3"
		>
			<div>
				<label for="documents-browse-query" class="mb-1 block text-sm font-medium text-gray-700"
					>Browse Query</label
				>
				<input
					id="documents-browse-query"
					aria-label="Browse Query"
					name="query"
					type="text"
					bind:value={browseQueryDraft}
					placeholder="e.g. title:First"
					class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
				/>
			</div>
			<div>
				<label for="documents-browse-cursor" class="mb-1 block text-sm font-medium text-gray-700"
					>Cursor</label
				>
				<input
					id="documents-browse-cursor"
					name="cursor"
					type="text"
					bind:value={browseCursorDraft}
					placeholder="Optional cursor token"
					class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
				/>
			</div>
			<div>
				<label for="documents-hits-per-page" class="mb-1 block text-sm font-medium text-gray-700"
					>Hits per page</label
				>
				<input
					id="documents-hits-per-page"
					name="hitsPerPage"
					type="number"
					min="1"
					bind:value={hitsPerPageDraft}
					class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
				/>
			</div>
			<div class="md:col-span-3">
				<button
					type="submit"
					class="rounded-md border border-gray-300 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-100"
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
					class="rounded-md border border-gray-300 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-100"
				>
					Load Next Page
				</button>
			</form>
			<p class="mb-4 text-xs text-gray-500">Next cursor: {documents.cursor}</p>
		{/if}

		{#if hasDocumentHits}
			<div class="space-y-3">
				{#each documents.hits as hit, hitIndex (`${hitObjectId(hit, hitIndex)}-${hitIndex}`)}
					{@const objectId = hitObjectId(hit, hitIndex)}
					<div class="rounded-md border border-gray-200 p-3">
						<div class="mb-2 flex items-center justify-between">
							<p class="font-mono text-sm text-gray-900">{objectId}</p>
							<form method="POST" action="?/deleteDocument" use:enhance>
								<input type="hidden" name="objectID" value={objectId} />
								<input type="hidden" name="query" value={browseQuery} />
								<input type="hidden" name="hitsPerPage" value={String(browseHitsPerPage)} />
								<button
									type="submit"
									aria-label={`Delete document ${objectId}`}
									class="rounded border border-red-300 px-3 py-1 text-xs text-red-700 hover:bg-red-50"
								>
									Delete
								</button>
							</form>
						</div>
						<pre
							class="overflow-x-auto rounded bg-gray-50 p-2 text-xs text-gray-700">{JSON.stringify(
								hit,
								null,
								2
							)}</pre>
					</div>
				{/each}
			</div>
		{:else}
			<p class="text-sm text-gray-500">No documents found</p>
		{/if}
	</div>
</div>
