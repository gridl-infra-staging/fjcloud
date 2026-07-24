import { fail } from '@sveltejs/kit';
import type { ApiClient } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import type { SecuritySourcesResponse } from '$lib/api/types';
import { errorMessage } from './document-management.server';

// Re-export the response type for convenience
export type SecuritySourcesPayload = SecuritySourcesResponse;

type SecuritySourceActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

type LoadSecuritySourcesOptions = {
	allowFallbackOnError?: boolean;
};

type SecuritySourcesRefreshResult = {
	securitySources?: SecuritySourcesPayload;
	securitySourcesReloaded?: boolean;
	securitySourcesLoadError?: string;
};

function failForSecuritySourceAction<T extends Record<string, unknown>>(
	error: unknown,
	payload: T
) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export function emptySecuritySourcesPayload(): SecuritySourcesPayload {
	return { sources: [] };
}

export async function loadSecuritySourcesPayload(
	api: ApiClient,
	indexName: string,
	options: LoadSecuritySourcesOptions = {}
): Promise<SecuritySourcesPayload> {
	try {
		return await api.getSecuritySources(indexName);
	} catch (error) {
		if (options.allowFallbackOnError === false) {
			throw error;
		}
		return emptySecuritySourcesPayload();
	}
}

async function refreshSecuritySourcesResult(
	api: ApiClient,
	indexName: string
): Promise<SecuritySourcesRefreshResult> {
	try {
		const securitySources = await loadSecuritySourcesPayload(api, indexName, {
			allowFallbackOnError: false
		});
		return {
			securitySources,
			securitySourcesReloaded: true,
			securitySourcesLoadError: ''
		};
	} catch (error) {
		return {
			securitySourcesLoadError: errorMessage(error, 'Failed to reload security sources')
		};
	}
}

export async function appendSecuritySourceAction({
	request,
	indexName,
	token
}: SecuritySourceActionArgs) {
	const data = await request.formData();
	const source = (data.get('source') as string | null)?.trim();
	const description = (data.get('description') as string | null)?.trim() ?? '';

	if (!source) {
		return fail(400, {
			securitySourceAppendError: 'source is required',
			securitySources: emptySecuritySourcesPayload()
		});
	}

	const api = createApiClient(token);
	try {
		await api.appendSecuritySource(indexName, { source, description });
	} catch (error) {
		const sessionFailure = mapDashboardSessionFailure(error);
		if (sessionFailure) return sessionFailure;
		const refreshResult = await refreshSecuritySourcesResult(api, indexName);
		return failForSecuritySourceAction(error, {
			securitySourceAppendError: errorMessage(error, 'Failed to add security source'),
			...refreshResult
		});
	}

	const refreshResult = await refreshSecuritySourcesResult(api, indexName);
	return {
		securitySourceAppended: true,
		...refreshResult
	};
}

export async function deleteSecuritySourceAction({
	request,
	indexName,
	token
}: SecuritySourceActionArgs) {
	const data = await request.formData();
	// Raw CIDR value — the client's pathSegment() handles encoding
	const source = (data.get('source') as string | null)?.trim();

	if (!source) {
		return fail(400, {
			securitySourceDeleteError: 'source is required',
			securitySources: emptySecuritySourcesPayload()
		});
	}

	const api = createApiClient(token);
	try {
		await api.deleteSecuritySource(indexName, source);
	} catch (error) {
		const sessionFailure = mapDashboardSessionFailure(error);
		if (sessionFailure) return sessionFailure;
		const refreshResult = await refreshSecuritySourcesResult(api, indexName);
		return failForSecuritySourceAction(error, {
			securitySourceDeleteError: errorMessage(error, 'Failed to delete security source'),
			...refreshResult
		});
	}

	const refreshResult = await refreshSecuritySourcesResult(api, indexName);
	return {
		securitySourceDeleted: true,
		...refreshResult
	};
}
