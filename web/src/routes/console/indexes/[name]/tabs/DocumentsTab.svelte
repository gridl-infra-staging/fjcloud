<script lang="ts">
	import { enhance } from '$app/forms';
	import type { SubmitFunction } from '@sveltejs/kit';
	import type { BrowseObjectsResponse, Index } from '$lib/api/types';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import {
		MAX_DOCUMENT_UPLOAD_BYTES,
		parseUploadFileRecords,
		type UploadFormat
	} from './documents-file-parser';
	import { buildAddObjectBatchPayload } from './documents_batch_payload';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';
	import {
		shouldToastSuccessCompletion,
		trackSuccessfulSubmitCompletion,
		type SuccessToastCompletionState
	} from './success_toast_completion';

	const DEFAULT_HITS_PER_PAGE = 20;
	const PREVIEW_LIMIT = 5;

	type Props = {
		index: Index;
		documents: BrowseObjectsResponse;
		documentsUploadSuccess: boolean;
		documentsAddSuccess: boolean;
		documentsBrowseSuccess: boolean;
		documentsUploadError: string;
		documentsAddError: string;
		documentsBrowseError: string;
		documentsDeleteError: string;
	};

	type ToastSuccessCompletionInput = SuccessToastCompletionState & {
		message: string;
	};

	let {
		index,
		documents,
		documentsUploadSuccess,
		documentsAddSuccess,
		documentsBrowseSuccess,
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
	let uploadSuccessCompletionVersion = $state(0);
	let lastDocumentsUploadSuccessToastState = $state(false);
	let lastToastedUploadSuccessCompletionVersion = $state(0);
	let addSuccessCompletionVersion = $state(0);
	let lastDocumentsAddSuccessToastState = $state(false);
	let lastToastedAddSuccessCompletionVersion = $state(0);
	let browseSuccessCompletionVersion = $state(0);
	let lastDocumentsBrowseSuccessToastState = $state(false);
	let lastToastedBrowseSuccessCompletionVersion = $state(0);

	const browseQuery = $derived(documents.query ?? '');
	const browseHitsPerPage = $derived(
		documents.hitsPerPage > 0 ? documents.hitsPerPage : DEFAULT_HITS_PER_PAGE
	);
	const uploadPreviewRecords = $derived(parsedUploadRecords.slice(0, PREVIEW_LIMIT));
	const uploadBatchPayload = $derived(buildAddObjectBatchPayload(parsedUploadRecords));

	function toastSuccessOnCompletion(input: ToastSuccessCompletionInput): number {
		const { completionVersion, lastToastedCompletionVersion, message } = input;
		if (shouldToastSuccessCompletion(input)) {
			toast.success(message, { duration: TOAST_DURATION_MS });
			return completionVersion;
		}
		return lastToastedCompletionVersion;
	}

	$effect(() => {
		lastToastedUploadSuccessCompletionVersion = toastSuccessOnCompletion({
			success: documentsUploadSuccess,
			completionVersion: uploadSuccessCompletionVersion,
			lastSuccess: lastDocumentsUploadSuccessToastState,
			lastToastedCompletionVersion: lastToastedUploadSuccessCompletionVersion,
			message: 'Documents uploaded.'
		});
		lastDocumentsUploadSuccessToastState = documentsUploadSuccess;
		lastToastedAddSuccessCompletionVersion = toastSuccessOnCompletion({
			success: documentsAddSuccess,
			completionVersion: addSuccessCompletionVersion,
			lastSuccess: lastDocumentsAddSuccessToastState,
			lastToastedCompletionVersion: lastToastedAddSuccessCompletionVersion,
			message: 'Document added.'
		});
		lastDocumentsAddSuccessToastState = documentsAddSuccess;
		lastToastedBrowseSuccessCompletionVersion = toastSuccessOnCompletion({
			success: documentsBrowseSuccess,
			completionVersion: browseSuccessCompletionVersion,
			lastSuccess: lastDocumentsBrowseSuccessToastState,
			lastToastedCompletionVersion: lastToastedBrowseSuccessCompletionVersion,
			message: 'Documents refreshed.'
		});
		lastDocumentsBrowseSuccessToastState = documentsBrowseSuccess;
	});

	const trackUploadDocumentsResult: SubmitFunction = () => {
		return trackSuccessfulSubmitCompletion(() => {
			uploadSuccessCompletionVersion += 1;
		});
	};

	const trackAddDocumentResult: SubmitFunction = () => {
		return trackSuccessfulSubmitCompletion(() => {
			addSuccessCompletionVersion += 1;
		});
	};

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

<div
	class="space-y-6"
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.documents}
	data-index={index.name}
>
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Documents</h2>
		<p class="mb-4 text-sm text-flapjack-ink/70">
			Upload JSON or CSV records, or add a single record manually.
		</p>

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
		<form method="POST" action="?/uploadDocuments" use:enhance={trackUploadDocumentsResult}>
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
		<form method="POST" action="?/addDocument" use:enhance={trackAddDocumentResult}>
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
</div>
