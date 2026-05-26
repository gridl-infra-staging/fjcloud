<script lang="ts">
	import type { StoredLogEntry } from './store';
	import { EXPORT_FILE_META, toCsv, toJson } from './exporters';

	let { getEntries } = $props<{ getEntries: () => StoredLogEntry[] }>();

	function triggerDownload(fileName: string, contentType: string, payload: string): void {
		const blob = new Blob([payload], { type: contentType });
		const url = URL.createObjectURL(blob);
		const anchor = document.createElement('a');
		anchor.href = url;
		anchor.download = fileName;
		anchor.click();
		URL.revokeObjectURL(url);
	}

	function exportJson(): void {
		triggerDownload(
			EXPORT_FILE_META.json.filename,
			EXPORT_FILE_META.json.contentType,
			toJson(getEntries())
		);
	}

	function exportCsv(): void {
		triggerDownload(
			EXPORT_FILE_META.csv.filename,
			EXPORT_FILE_META.csv.contentType,
			toCsv(getEntries())
		);
	}
</script>

<div class="flex items-center gap-2" data-testid="api-log-export-controls">
	<button
		type="button"
		class="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100"
		data-testid="api-log-export-json"
		onclick={exportJson}
	>
		Export JSON
	</button>
	<button
		type="button"
		class="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100"
		data-testid="api-log-export-csv"
		onclick={exportCsv}
	>
		Export CSV
	</button>
</div>
