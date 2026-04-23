/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/dashboard/indexes/[name]/document-management.server.ts.
 */
import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { customerFacingErrorMessage, mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import type { AddObjectsRequest, BrowseObjectsRequest, BrowseObjectsResponse } from '$lib/api/types';

export const DEFAULT_DOCUMENT_HITS_PER_PAGE = 20;

export function errorMessage(e: unknown, fallback: string): string {
	return customerFacingErrorMessage(e, fallback);
}

export function parseJsonObject<T extends object>(raw: string, fieldName: string): T {
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		throw new Error(`${fieldName} must be valid JSON`);
	}

	if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
		throw new Error(`${fieldName} must be a JSON object`);
	}

	return parsed as T;
}

export function emptyDocumentsBrowse(query = ''): BrowseObjectsResponse {
	return {
		hits: [],
		cursor: null,
		nbHits: 0,
		page: 0,
		nbPages: 0,
		hitsPerPage: DEFAULT_DOCUMENT_HITS_PER_PAGE,
		query,
		params: ''
	};
}

export function parsePositiveInt(raw: FormDataEntryValue | null, fieldName: string): number {
	const value = (raw as string | null)?.trim() ?? '';
	if (!/^\d+$/.test(value)) {
		throw new Error(`${fieldName} must be a positive integer`);
	}
	const parsed = Number.parseInt(value, 10);
	if (parsed <= 0) {
		throw new Error(`${fieldName} must be a positive integer`);
	}
	return parsed;
}

function parseOptionalCursor(raw: FormDataEntryValue | null): string | undefined {
	if (raw === null) return undefined;

	const cursor = String(raw);
	if (cursor.length > 0 && cursor.trim().length === 0) {
		throw new Error('cursor must not be empty when provided');
	}

	const normalized = cursor.trim();
	return normalized.length > 0 ? normalized : undefined;
}

export function parseBrowseRequestFromForm(data: FormData): BrowseObjectsRequest {
	const query = (data.get('query') as string | null)?.trim() ?? '';
	let hitsPerPage = DEFAULT_DOCUMENT_HITS_PER_PAGE;
	const hitsPerPageRaw = (data.get('hitsPerPage') as string | null)?.trim() ?? '';
	if (hitsPerPageRaw.length > 0) {
		hitsPerPage = parsePositiveInt(hitsPerPageRaw, 'hitsPerPage');
	}

	const cursor = parseOptionalCursor(data.get('cursor'));
	return {
		query,
		hitsPerPage,
		...(cursor ? { cursor } : {})
	};
}

export function parseRefreshBrowseRequestFromForm(data: FormData): BrowseObjectsRequest {
	const query = (data.get('query') as string | null)?.trim() ?? '';
	let hitsPerPage = DEFAULT_DOCUMENT_HITS_PER_PAGE;
	const hitsPerPageRaw = (data.get('hitsPerPage') as string | null)?.trim() ?? '';
	if (hitsPerPageRaw.length > 0) {
		hitsPerPage = parsePositiveInt(hitsPerPageRaw, 'hitsPerPage');
	}

	return { query, hitsPerPage };
}

export function normalizeDocumentsBrowseResponse(
	result: Record<string, unknown> | null | undefined,
	queryFallback = ''
): BrowseObjectsResponse {
	if (!result) {
		return emptyDocumentsBrowse(queryFallback);
	}

	const hits = Array.isArray(result.hits)
		? result.hits.filter((hit): hit is Record<string, unknown> => typeof hit === 'object' && hit !== null)
		: [];

	const nbHits =
		typeof result.nbHits === 'number' && Number.isFinite(result.nbHits) ? result.nbHits : hits.length;
	const page = typeof result.page === 'number' && Number.isFinite(result.page) ? result.page : 0;
	const nbPages =
		typeof result.nbPages === 'number' && Number.isFinite(result.nbPages) ? result.nbPages : 0;
	const hitsPerPage =
		typeof result.hitsPerPage === 'number' && Number.isFinite(result.hitsPerPage)
			? result.hitsPerPage
			: DEFAULT_DOCUMENT_HITS_PER_PAGE;
	const query = typeof result.query === 'string' ? result.query : queryFallback;
	const params = typeof result.params === 'string' ? result.params : '';
	const cursor = typeof result.cursor === 'string' ? result.cursor : null;

	return {
		hits,
		cursor,
		nbHits,
		page,
		nbPages,
		hitsPerPage,
		query,
		params
	};
}

function parseBatchRequest(rawBatch: string): AddObjectsRequest {
	const parsed = parseJsonObject<{ requests?: unknown }>(rawBatch, 'batch');
	if (!Array.isArray(parsed.requests) || parsed.requests.length === 0) {
		throw new Error('batch must include at least one request');
	}

	for (const request of parsed.requests) {
		if (typeof request !== 'object' || request === null || Array.isArray(request)) {
			throw new Error('batch requests must be JSON objects');
		}
		if (typeof (request as Record<string, unknown>).action !== 'string') {
			throw new Error('batch requests must include an action');
		}
	}

	return { requests: parsed.requests as AddObjectsRequest['requests'] };
}

type DocumentActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

function failForDocumentAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export async function uploadDocumentsAction({ request, indexName, token }: DocumentActionArgs) {
	const data = await request.formData();

	let refreshRequest: BrowseObjectsRequest;
	try {
		refreshRequest = parseRefreshBrowseRequestFromForm(data);
	} catch (e) {
		return failForDocumentAction(e, {
			documentsUploadError: errorMessage(e, 'Invalid browse refresh request'),
			documents: emptyDocumentsBrowse()
		});
	}

	const rawBatch = (data.get('batch') as string | null)?.trim();
	if (!rawBatch) {
		return fail(400, {
			documentsUploadError: 'batch is required',
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}

	let batchRequest: AddObjectsRequest;
	try {
		batchRequest = parseBatchRequest(rawBatch);
	} catch (e) {
		return failForDocumentAction(e, {
			documentsUploadError: errorMessage(e, 'Invalid batch payload'),
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}

	const api = createApiClient(token);
	try {
		await api.addObjects(indexName, batchRequest);
		const documents = normalizeDocumentsBrowseResponse(
			(await api.browseObjects(indexName, refreshRequest)) as Record<string, unknown>,
			refreshRequest.query ?? ''
		);
		return { documentsUploadSuccess: true, documents };
	} catch (e) {
		return failForDocumentAction(e, {
			documentsUploadError: errorMessage(e, 'Failed to upload documents'),
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}
}

export async function addDocumentAction({ request, indexName, token }: DocumentActionArgs) {
	const data = await request.formData();

	let refreshRequest: BrowseObjectsRequest;
	try {
		refreshRequest = parseRefreshBrowseRequestFromForm(data);
	} catch (e) {
		return failForDocumentAction(e, {
			documentsAddError: errorMessage(e, 'Invalid browse refresh request'),
			documents: emptyDocumentsBrowse()
		});
	}

	const rawDocument = (data.get('document') as string | null)?.trim();
	if (!rawDocument) {
		return fail(400, {
			documentsAddError: 'document is required',
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}

	let documentBody: Record<string, unknown>;
	try {
		documentBody = parseJsonObject<Record<string, unknown>>(rawDocument, 'document');
	} catch (e) {
		return failForDocumentAction(e, {
			documentsAddError: errorMessage(e, 'Invalid document JSON'),
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}

	const api = createApiClient(token);
	try {
		await api.addObjects(indexName, {
			requests: [{ action: 'addObject', body: documentBody }]
		});
		const documents = normalizeDocumentsBrowseResponse(
			(await api.browseObjects(indexName, refreshRequest)) as Record<string, unknown>,
			refreshRequest.query ?? ''
		);
		return { documentsAddSuccess: true, documents };
	} catch (e) {
		return failForDocumentAction(e, {
			documentsAddError: errorMessage(e, 'Failed to add document'),
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}
}

export async function browseDocumentsAction({ request, indexName, token }: DocumentActionArgs) {
	const data = await request.formData();

	let browseRequest: BrowseObjectsRequest;
	try {
		browseRequest = parseBrowseRequestFromForm(data);
	} catch (e) {
		return failForDocumentAction(e, {
			documentsBrowseError: errorMessage(e, 'Invalid browse request'),
			documents: emptyDocumentsBrowse()
		});
	}

	const api = createApiClient(token);
	try {
		const documents = normalizeDocumentsBrowseResponse(
			(await api.browseObjects(indexName, browseRequest)) as Record<string, unknown>,
			browseRequest.query ?? ''
		);
		return { documentsBrowseSuccess: true, documents };
	} catch (e) {
		return failForDocumentAction(e, {
			documentsBrowseError: errorMessage(e, 'Failed to browse documents'),
			documents: emptyDocumentsBrowse(browseRequest.query ?? '')
		});
	}
}

export async function deleteDocumentAction({ request, indexName, token }: DocumentActionArgs) {
	const data = await request.formData();

	let refreshRequest: BrowseObjectsRequest;
	try {
		refreshRequest = parseRefreshBrowseRequestFromForm(data);
	} catch (e) {
		return failForDocumentAction(e, {
			documentsDeleteError: errorMessage(e, 'Invalid browse refresh request'),
			documents: emptyDocumentsBrowse()
		});
	}

	const objectID = (data.get('objectID') as string | null)?.trim();
	if (!objectID) {
		return fail(400, {
			documentsDeleteError: 'objectID is required',
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}

	const api = createApiClient(token);
	try {
		await api.deleteObject(indexName, objectID);
		const documents = normalizeDocumentsBrowseResponse(
			(await api.browseObjects(indexName, refreshRequest)) as Record<string, unknown>,
			refreshRequest.query ?? ''
		);
		return { documentsDeleteSuccess: true, documents };
	} catch (e) {
		return failForDocumentAction(e, {
			documentsDeleteError: errorMessage(e, 'Failed to delete document'),
			documents: emptyDocumentsBrowse(refreshRequest.query ?? '')
		});
	}
}
