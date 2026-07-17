import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import { ApiRequestError } from '$lib/api/client';
import type { PersonalizationProfile, PersonalizationStrategy } from '$lib/api/types';
import { errorMessage, parseJsonObject } from './document-management.server';
import { parsePersonalizationStrategy } from './tabs/personalization_strategy_dialog';

type PersonalizationActionArgs = {
	request?: Request;
	indexName: string;
	token: string | undefined;
};

function failForPersonalizationAction<T extends Record<string, unknown>>(
	error: unknown,
	payload: T
) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

export async function savePersonalizationStrategyAction({
	request,
	indexName,
	token
}: PersonalizationActionArgs) {
	if (!request) return fail(400, { personalizationError: 'Strategy JSON is required' });
	const data = await request.formData();
	const rawStrategy = (data.get('strategy') as string)?.trim();
	if (!rawStrategy) return fail(400, { personalizationError: 'Strategy JSON is required' });

	let strategy: PersonalizationStrategy;
	try {
		strategy = parsePersonalizationStrategy(parseJsonObject(rawStrategy, 'strategy'));
	} catch (e) {
		return failForPersonalizationAction(e, {
			personalizationError: errorMessage(e, 'Invalid strategy JSON')
		});
	}

	const api = createApiClient(token);
	try {
		await api.savePersonalizationStrategy(indexName, strategy);
		return { personalizationStrategySaved: true };
	} catch (e) {
		return failForPersonalizationAction(e, {
			personalizationError: errorMessage(e, 'Failed to save personalization strategy')
		});
	}
}

export async function deletePersonalizationStrategyAction({
	indexName,
	token
}: PersonalizationActionArgs) {
	const api = createApiClient(token);
	try {
		await api.deletePersonalizationStrategy(indexName);
		return { personalizationStrategyDeleted: true };
	} catch (e) {
		return failForPersonalizationAction(e, {
			personalizationError: errorMessage(e, 'Failed to delete personalization strategy')
		});
	}
}

export async function getPersonalizationProfileAction({
	request,
	indexName,
	token
}: PersonalizationActionArgs) {
	if (!request) {
		return fail(400, {
			personalizationError: 'userToken is required',
			personalizationProfileLookupAttempted: true
		});
	}
	const data = await request.formData();
	const userToken = (data.get('userToken') as string)?.trim();
	if (!userToken) {
		return fail(400, {
			personalizationError: 'userToken is required',
			personalizationProfileLookupAttempted: true
		});
	}

	const api = createApiClient(token);
	try {
		const profile: PersonalizationProfile = await api.getPersonalizationProfile(
			indexName,
			userToken
		);
		return { personalizationProfile: profile, personalizationProfileLookupAttempted: true };
	} catch (e) {
		if (e instanceof ApiRequestError && e.status === 404) {
			return { personalizationProfile: null, personalizationProfileLookupAttempted: true };
		}
		return failForPersonalizationAction(e, {
			personalizationError: errorMessage(e, 'Failed to load personalization profile'),
			personalizationProfileLookupAttempted: true
		});
	}
}

export async function deletePersonalizationProfileAction({
	request,
	indexName,
	token
}: PersonalizationActionArgs) {
	if (!request) {
		return fail(400, {
			personalizationError: 'userToken is required',
			personalizationProfileLookupAttempted: true
		});
	}
	const data = await request.formData();
	const userToken = (data.get('userToken') as string)?.trim();
	if (!userToken) {
		return fail(400, {
			personalizationError: 'userToken is required',
			personalizationProfileLookupAttempted: true
		});
	}

	const api = createApiClient(token);
	try {
		await api.deletePersonalizationProfile(indexName, userToken);
		return {
			personalizationProfileDeleted: true,
			personalizationProfile: null,
			personalizationProfileLookupAttempted: false
		};
	} catch (e) {
		return failForPersonalizationAction(e, {
			personalizationError: errorMessage(e, 'Failed to delete personalization profile'),
			personalizationProfileLookupAttempted: true
		});
	}
}
