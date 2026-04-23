/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_2_feature_gaps/fjcloud_dev/web/src/routes/dashboard/indexes/[name]/security-sources.server.ts.
 */
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

function failForSecuritySourceAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export function emptySecuritySourcesPayload(): SecuritySourcesPayload {
	return { sources: [] };
}

export async function loadSecuritySourcesPayload(
	api: ApiClient,
	indexName: string
): Promise<SecuritySourcesPayload> {
	try {
		return await api.getSecuritySources(indexName);
	} catch {
		return emptySecuritySourcesPayload();
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
		// Refresh list so user sees current state alongside the error
		const securitySources = await loadSecuritySourcesPayload(api, indexName);
		return failForSecuritySourceAction(error, {
			securitySourceAppendError: errorMessage(error, 'Failed to add security source'),
			securitySources
		});
	}

	// Refresh list after successful append
	const securitySources = await loadSecuritySourcesPayload(api, indexName);
	return {
		securitySourceAppended: true,
		securitySources
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
		const securitySources = await loadSecuritySourcesPayload(api, indexName);
		return failForSecuritySourceAction(error, {
			securitySourceDeleteError: errorMessage(error, 'Failed to delete security source'),
			securitySources
		});
	}

	const securitySources = await loadSecuritySourcesPayload(api, indexName);
	return {
		securitySourceDeleted: true,
		securitySources
	};
}
