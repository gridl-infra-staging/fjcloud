import type { PageServerLoad, Actions } from './$types';
import { createApiClient } from '$lib/server/api';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { fail } from '@sveltejs/kit';
import { redirect } from '@sveltejs/kit';
import { EMPTY_SCOPE_REQUIRED_ERROR } from './api_keys_constants';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';
import type { Index } from '$lib/api/types';

function parseOptionalTextField(data: FormData, field: string): string | null {
	const value = data.get(field);
	if (typeof value !== 'string') {
		return null;
	}

	const normalized = value.trim();
	return normalized === '' ? null : normalized;
}

function parseOptionalIntegerField(data: FormData, field: string): number | null {
	const value = parseOptionalTextField(data, field);
	if (value === null) {
		return null;
	}

	const parsed = Number(value);
	if (!Number.isInteger(parsed)) {
		throw new Error(`${field} must be an integer`);
	}
	return parsed;
}

function validatePositiveIntegerField(value: number | null, field: string): void {
	if (value !== null && value < 1) {
		throw new Error(`${field} must be at least 1`);
	}
}

async function apiKeyIsAbsentAfterRevokeError(
	api: ReturnType<typeof createApiClient>,
	keyId: string
): Promise<boolean> {
	const apiKeys = await api.getApiKeys();
	return !apiKeys.some((apiKey) => apiKey.id === keyId);
}

function parseStringListField(data: FormData, field: string): string[] {
	return data
		.getAll(field)
		.filter((value): value is string => typeof value === 'string')
		.map((value) => value.trim())
		.filter((value) => value !== '');
}

function parseOptionalTimezoneOffsetField(data: FormData, field: string): number | null {
	const value = parseOptionalTextField(data, field);
	if (value === null) {
		return null;
	}

	const parsed = Number(value);
	if (!Number.isInteger(parsed)) {
		throw new Error(`${field} must be an integer`);
	}
	return parsed;
}

function parseOptionalDateTimeField(
	data: FormData,
	field: string,
	timezoneOffsetField: string
): string | null {
	const value = parseOptionalTextField(data, field);
	if (value === null) {
		return null;
	}

	const datetimeLocalMatch = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
	if (datetimeLocalMatch) {
		const timezoneOffsetMinutes = parseOptionalTimezoneOffsetField(data, timezoneOffsetField);
		const [, year, month, day, hour, minute, second = '00'] = datetimeLocalMatch;
		const parsedYear = Number(year);
		const parsedMonth = Number(month);
		const parsedDay = Number(day);
		const parsedHour = Number(hour);
		const parsedMinute = Number(minute);
		const parsedSecond = Number(second);

		const hasOutOfRangeComponent =
			parsedMonth < 1 ||
			parsedMonth > 12 ||
			parsedDay < 1 ||
			parsedDay > 31 ||
			parsedHour < 0 ||
			parsedHour > 23 ||
			parsedMinute < 0 ||
			parsedMinute > 59 ||
			parsedSecond < 0 ||
			parsedSecond > 59;
		if (hasOutOfRangeComponent) {
			throw new Error(`${field} must be a valid date-time`);
		}

		const utcDate = new Date(
			Date.UTC(parsedYear, parsedMonth - 1, parsedDay, parsedHour, parsedMinute, parsedSecond)
		);
		const isCalendarDateMismatch =
			utcDate.getUTCFullYear() !== parsedYear ||
			utcDate.getUTCMonth() !== parsedMonth - 1 ||
			utcDate.getUTCDate() !== parsedDay ||
			utcDate.getUTCHours() !== parsedHour ||
			utcDate.getUTCMinutes() !== parsedMinute ||
			utcDate.getUTCSeconds() !== parsedSecond;
		if (isCalendarDateMismatch) {
			throw new Error(`${field} must be a valid date-time`);
		}

		const utcMillis = utcDate.getTime() + (timezoneOffsetMinutes ?? 0) * 60_000;
		return new Date(utcMillis).toISOString().replace('.000Z', 'Z');
	}

	const parsed = new Date(value);
	if (Number.isNaN(parsed.getTime())) {
		throw new Error(`${field} must be a valid date-time`);
	}

	return parsed.toISOString().replace('.000Z', 'Z');
}

export const load: PageServerLoad = async ({ locals, url }) => {
	const api = createApiClient(locals.user?.token);
	const selectedIndexFilter = url.searchParams.get('index')?.trim() ?? '';
	let apiKeys;
	try {
		apiKeys = await api.getApiKeys();
	} catch (error) {
		if (isDashboardSessionExpiredError(error)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		return {
			apiKeys: [],
			indexOptions: [],
			selectedIndexFilter,
			loadError: customerFacingErrorMessage(error, 'Failed to load API keys')
		};
	}

	let indexOptions: Index[] = [];
	try {
		indexOptions = await retryTransientDashboardApiRequest(() => api.getIndexes());
	} catch (error) {
		if (isDashboardSessionExpiredError(error)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
	}

	return { apiKeys, indexOptions, selectedIndexFilter };
};

export const actions: Actions = {
	create: async ({ request, locals }) => {
		const data = await request.formData();
		const name = (data.get('name') as string)?.trim();
		if (!name) return fail(400, { error: 'Name is required' });

		const scopes = data
			.getAll('scope')
			.filter((value): value is string => typeof value === 'string');
		if (scopes.length === 0) return fail(400, { error: EMPTY_SCOPE_REQUIRED_ERROR });

		let maxHitsPerQuery: number | null;
		let maxQueriesPerIpPerHour: number | null;
		try {
			maxHitsPerQuery = parseOptionalIntegerField(data, 'max_hits_per_query');
			maxQueriesPerIpPerHour = parseOptionalIntegerField(data, 'max_queries_per_ip_per_hour');
			validatePositiveIntegerField(maxHitsPerQuery, 'max_hits_per_query');
			validatePositiveIntegerField(maxQueriesPerIpPerHour, 'max_queries_per_ip_per_hour');
		} catch (error) {
			return fail(400, { error: customerFacingErrorMessage(error, 'Invalid numeric key limits') });
		}

		const description = parseOptionalTextField(data, 'description');
		const indexes = parseStringListField(data, 'indexes');
		const restrictSources = parseStringListField(data, 'restrict_sources');
		let expiresAt: string | null;
		try {
			expiresAt = parseOptionalDateTimeField(
				data,
				'expires_at',
				'expires_at_timezone_offset_minutes'
			);
		} catch (error) {
			return fail(400, { error: customerFacingErrorMessage(error, 'Invalid key expiration date') });
		}

		const api = createApiClient(locals.user?.token);
		try {
			const result = await api.createApiKey({
				name,
				scopes,
				description,
				indexes,
				restrict_sources: restrictSources,
				expires_at: expiresAt,
				max_hits_per_query: maxHitsPerQuery,
				max_queries_per_ip_per_hour: maxQueriesPerIpPerHour
			});
			return { createdKey: result.key, createdKeyId: result.id };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return fail(400, { error: customerFacingErrorMessage(error, 'Failed to create API key') });
		}
	},
	revoke: async ({ request, locals }) => {
		const data = await request.formData();
		const keyId = data.get('keyId') as string;
		if (!keyId) return fail(400, { error: 'Missing key ID' });

		const keyName = ((data.get('keyName') as string) ?? '').trim();

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteApiKey(keyId);
			return { revokedKeyName: keyName };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			try {
				if (await apiKeyIsAbsentAfterRevokeError(api, keyId)) {
					return { revokedKeyName: keyName };
				}
			} catch {
				// Preserve the original revoke failure when the confirmation read
				// also fails; the read is only a best-effort idempotency check.
			}
			return fail(400, { error: 'Failed to revoke API key' });
		}
	}
};
