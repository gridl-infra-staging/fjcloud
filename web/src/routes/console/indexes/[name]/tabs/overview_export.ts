import { applyAction, deserialize } from '$app/forms';

export const EXPORT_HITS_PER_PAGE = 1000;
export const EXPORT_ENTRY_LIMIT = 10000;

export type ExportBrowsePage = {
	cursor: string | null;
	hits: Record<string, unknown>[];
};

export type OverviewExportProgress = {
	exportedCount: number;
	totalDocuments: number;
};

export function browsePageFromActionResult(result: unknown): ExportBrowsePage {
	if (!result || typeof result !== 'object' || !('type' in result)) {
		throw new Error('Unexpected browse response');
	}

	const actionResult = result as {
		type: string;
		data?: Record<string, unknown>;
	};

	if (actionResult.type === 'failure') {
		const errorMessage = actionResult.data?.documentsBrowseError;
		if (typeof errorMessage === 'string' && errorMessage.trim().length > 0) {
			throw new Error(errorMessage);
		}
		throw new Error('Failed to browse documents for export');
	}
	if (actionResult.type !== 'success') {
		throw new Error('Failed to browse documents for export');
	}

	const documents = actionResult.data?.documents;
	if (!documents || typeof documents !== 'object') {
		throw new Error('Browse response did not include documents');
	}

	const docs = documents as Record<string, unknown>;
	const hits = Array.isArray(docs.hits)
		? docs.hits.filter(
				(hit): hit is Record<string, unknown> => typeof hit === 'object' && hit !== null
			)
		: [];
	const cursor = typeof docs.cursor === 'string' && docs.cursor.length > 0 ? docs.cursor : null;
	return { cursor, hits };
}

export async function requestOverviewBrowseActionPage(cursor: string | null): Promise<unknown> {
	const body = new FormData();
	body.set('query', '');
	body.set('hitsPerPage', String(EXPORT_HITS_PER_PAGE));
	if (cursor) {
		body.set('cursor', cursor);
	}

	const response = await fetch('?/browseDocuments', {
		method: 'POST',
		headers: {
			'x-sveltekit-action': 'true'
		},
		body
	});
	const actionResult = deserialize(await response.text());
	if (actionResult.type === 'redirect' || actionResult.type === 'error') {
		await applyAction(actionResult);
		throw new Error('Failed to browse documents for export');
	}

	return actionResult;
}

export async function collectOverviewExportRecords({
	indexEntries,
	requestBrowsePage = requestOverviewBrowseActionPage,
	onProgress
}: {
	indexEntries: number;
	requestBrowsePage?: (cursor: string | null) => Promise<unknown>;
	onProgress?: (progress: OverviewExportProgress) => void;
}): Promise<Record<string, unknown>[]> {
	if (indexEntries > EXPORT_ENTRY_LIMIT) {
		throw new Error('Export is limited to indexes with 10,000 entries or fewer');
	}
	if (indexEntries === 0) {
		return [];
	}

	const exportedHits: Record<string, unknown>[] = [];
	let cursor: string | null = null;
	try {
		do {
			const actionResult = await requestBrowsePage(cursor);
			const page = browsePageFromActionResult(actionResult);
			exportedHits.push(...page.hits);
			onProgress?.({
				exportedCount: exportedHits.length,
				totalDocuments: indexEntries
			});
			cursor = page.cursor;
		} while (cursor);
	} catch (error) {
		const message =
			error instanceof Error && error.message.trim().length > 0
				? error.message
				: 'Failed to browse documents for export';
		throw new Error(
			`Export failed after ${exportedHits.length}/${indexEntries} documents: ${message}`
		);
	}

	return exportedHits;
}
