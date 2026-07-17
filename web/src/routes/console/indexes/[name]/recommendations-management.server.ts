import { fail } from '@sveltejs/kit';
import { sanitizeRecommendationRequest } from '$lib/recommendations/config';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import type { RecommendationsBatchRequest, RecommendationsBatchResponse } from '$lib/api/types';
import { errorMessage, parseJsonObject } from './document-management.server';

type RecommendationActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

function failForRecommendationAction<T extends Record<string, unknown>>(
	error: unknown,
	payload: T
) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export async function recommendAction({ request, indexName, token }: RecommendationActionArgs) {
	const data = await request.formData();
	const rawRequest = (data.get('request') as string)?.trim();
	if (!rawRequest) return fail(400, { recommendationsError: 'Recommendations JSON is required' });

	let requestBody: RecommendationsBatchRequest;
	try {
		requestBody = parseJsonObject<RecommendationsBatchRequest>(rawRequest, 'request');
		if (!Array.isArray(requestBody.requests)) {
			throw new Error('request.requests must be an array');
		}
		if (requestBody.requests.length !== 1) {
			throw new Error('request.requests must contain exactly one request');
		}
		requestBody = {
			requests: [sanitizeRecommendationRequest(indexName, requestBody.requests[0])]
		};
	} catch (error) {
		return failForRecommendationAction(error, {
			recommendationsError: errorMessage(error, 'Invalid recommendations JSON')
		});
	}

	const api = createApiClient(token);
	try {
		const recommendationsResponse: RecommendationsBatchResponse = await api.recommend(
			indexName,
			requestBody
		);
		return { recommendationsResponse };
	} catch (error) {
		return failForRecommendationAction(error, {
			recommendationsError: errorMessage(error, 'Failed to fetch recommendations')
		});
	}
}
