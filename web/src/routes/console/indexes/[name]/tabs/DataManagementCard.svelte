<script lang="ts">
	import { enhance } from '$app/forms';
	import Tooltip from '$lib/components/Tooltip.svelte';
	import { formatNumber } from '$lib/format';
	import { tick } from 'svelte';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import type { Index } from '$lib/api/types';
	import { MAX_DOCUMENT_UPLOAD_BYTES, parseUploadFileRecords } from './documents-file-parser';
	import { buildAddObjectBatchPayload } from './documents_batch_payload';
	import { collectOverviewExportRecords, EXPORT_ENTRY_LIMIT } from './overview_export';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';

	type Props = {
		index: Index;
		documentsUploadError?: string;
		onOverviewImportDocumentCountChange?: ((count: number) => void) | null;
		onOverviewImportUploadSettled?: ((uploadSucceeded: boolean) => void) | null;
	};

	let {
		index,
		documentsUploadError = '',
		onOverviewImportDocumentCountChange = null,
		onOverviewImportUploadSettled = null
	}: Props = $props();

	let exportInFlight = $state(false);
	let exportProgressCount = $state(0);
	let importInFlight = $state(false);
	let importBatchPayload = $state('');
	let localDataManagementError = $state('');
	let importFileInputElement = $state<HTMLInputElement | null>(null);
	let importFormElement = $state<HTMLFormElement | null>(null);

	const indexProvisioned = $derived(index.endpoint !== null);
	const dataManagementAlert = $derived(localDataManagementError || documentsUploadError);
	const unavailableControlTooltip = 'Available once your index is provisioned';
	const exportButtonLabel = $derived(
		exportInFlight
			? `Exporting ${formatNumber(exportProgressCount)} of ${formatNumber(index.entries)} docs…`
			: 'Export Index'
	);
	const importButtonLabel = $derived(importInFlight ? 'Uploading…' : 'Import Documents');

	const IMPORT_REFRESH_HITS_PER_PAGE = 20;

	function resolveUploadActionSucceeded(result: unknown): boolean | null {
		if (typeof result !== 'object' || result === null) return null;
		const resultData = (result as { data?: unknown }).data;
		if (typeof resultData !== 'object' || resultData === null) return null;
		if ('documentsUploadSuccess' in resultData) {
			return (resultData as { documentsUploadSuccess?: unknown }).documentsUploadSuccess === true;
		}
		if ('documentsUploadError' in resultData) {
			return false;
		}
		return null;
	}

	function setLocalDataManagementError(message: string): void {
		localDataManagementError = message;
	}

	function clearLocalDataManagementError(): void {
		localDataManagementError = '';
	}

	function exportSuccessMessage(exportedCount: number): string {
		const documentLabel = exportedCount === 1 ? 'document' : 'documents';
		return `Exported ${formatNumber(exportedCount)} ${documentLabel}.`;
	}

	function emitExportSuccessToast(exportedCount: number): void {
		toast.success(exportSuccessMessage(exportedCount), { duration: TOAST_DURATION_MS });
	}

	function sanitizeExportFilenameSegment(indexName: string): string {
		const normalized = indexName
			.trim()
			// Keep browser download names free of path separators and control chars.
			.replace(/[^A-Za-z0-9._-]+/g, '_')
			.replace(/_+/g, '_')
			.replace(/^\.+/, '')
			.replace(/^_+|_+$/g, '');
		return normalized.length > 0 ? normalized : 'index';
	}

	function exportFilenameForIndex(indexName: string): string {
		const dayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
		return `${sanitizeExportFilenameSegment(indexName)}-export-${dayStamp}.json`;
	}

	function downloadExport(records: Record<string, unknown>[]): void {
		const blob = new Blob([JSON.stringify(records, null, 2)], { type: 'application/json' });
		const objectUrl = URL.createObjectURL(blob);
		const anchor = document.createElement('a');
		anchor.href = objectUrl;
		anchor.download = exportFilenameForIndex(index.name);
		anchor.style.display = 'none';
		document.body.appendChild(anchor);
		anchor.click();
		anchor.remove();
		window.setTimeout(() => {
			URL.revokeObjectURL(objectUrl);
		}, 0);
	}

	async function handleOverviewExportClick(): Promise<void> {
		if (!indexProvisioned || exportInFlight) return;

		clearLocalDataManagementError();
		if (index.entries > EXPORT_ENTRY_LIMIT) {
			setLocalDataManagementError(
				`This index has ${formatNumber(index.entries)} documents. Browser-side export is limited to 10,000 documents. Contact support to export larger indexes.`
			);
			return;
		}

		exportInFlight = true;
		exportProgressCount = 0;
		try {
			const exportedHits = await collectOverviewExportRecords({
				indexEntries: index.entries,
				onProgress: ({ exportedCount }) => {
					exportProgressCount = exportedCount;
				}
			});
			downloadExport(exportedHits);
			emitExportSuccessToast(exportedHits.length);
		} catch (error) {
			setLocalDataManagementError(
				error instanceof Error ? error.message : 'Failed to export documents'
			);
		} finally {
			exportInFlight = false;
		}
	}

	function openImportPicker(): void {
		if (!indexProvisioned || importInFlight) return;
		clearLocalDataManagementError();
		importFileInputElement?.click();
	}

	async function handleOverviewImportFileChange(event: Event): Promise<void> {
		const input = event.currentTarget;
		if (!(input instanceof HTMLInputElement)) return;
		const file = input.files?.[0];
		input.value = '';
		if (!file) return;

		clearLocalDataManagementError();
		if (file.size > MAX_DOCUMENT_UPLOAD_BYTES) {
			setLocalDataManagementError('File exceeds 100MB limit');
			return;
		}

		try {
			const parsedFile = await parseUploadFileRecords(file);
			onOverviewImportDocumentCountChange?.(parsedFile.records.length);
			importBatchPayload = buildAddObjectBatchPayload(parsedFile.records);
			await tick();
			importInFlight = true;
			try {
				importFormElement?.requestSubmit();
			} catch {
				// jsdom does not implement requestSubmit; keep the state machine stable in tests.
			}
		} catch (error) {
			importInFlight = false;
			setLocalDataManagementError(error instanceof Error ? error.message : 'Failed to parse file');
		}
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.overview}
>
	<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Data Management</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Export downloads all documents as JSON. Import adds new documents without replacing existing
		ones.
	</p>
	<div class="flex flex-wrap gap-3">
		<button
			type="button"
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-50"
			data-testid="overview-export-btn"
			disabled={!indexProvisioned || exportInFlight || importInFlight}
			onclick={() => {
				void handleOverviewExportClick();
			}}
		>
			{exportButtonLabel}
		</button>
		<button
			type="button"
			class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-50"
			data-testid="overview-import-btn"
			disabled={!indexProvisioned || exportInFlight || importInFlight}
			onclick={openImportPicker}
		>
			{importButtonLabel}
		</button>
	</div>
	<input
		bind:this={importFileInputElement}
		id="overview-import-file"
		aria-label="Import JSON or CSV file"
		type="file"
		accept=".json,.csv,application/json,text/csv"
		onchange={handleOverviewImportFileChange}
		class="sr-only"
	/>
	<form
		bind:this={importFormElement}
		method="POST"
		action="?/uploadDocuments"
		use:enhance={() => {
			importInFlight = true;
			return async ({ result, update }) => {
				await update();
				importInFlight = false;
				importBatchPayload = '';
				const uploadSucceeded = resolveUploadActionSucceeded(result);
				if (uploadSucceeded === null) return;
				onOverviewImportUploadSettled?.(uploadSucceeded);
			};
		}}
		class="hidden"
	>
		<input type="hidden" name="batch" value={importBatchPayload} />
		<input type="hidden" name="query" value="" />
		<input type="hidden" name="hitsPerPage" value={String(IMPORT_REFRESH_HITS_PER_PAGE)} />
	</form>
	{#if !indexProvisioned}
		<div class="mt-3 flex items-center gap-2">
			<p class="text-sm text-flapjack-ink/60">{unavailableControlTooltip}</p>
			<Tooltip
				triggerLabel="Why data management is unavailable"
				message={unavailableControlTooltip}
			/>
		</div>
	{/if}
	{#if dataManagementAlert}
		<div
			class="mt-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
			role="alert"
			aria-label="overview-export-import-alert"
		>
			{dataManagementAlert}
		</div>
	{/if}
</div>
