import { fail, redirect } from '@sveltejs/kit';
import type { PageServerLoad, Actions } from './$types';
import { ApiRequestError } from '$lib/api/client';
import type { Index } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import { DEFAULT_INTERNAL_REGIONS } from '$lib/format';
import type { IndexTemplateId } from '$lib/search_templates';
import { getIndexTemplateServerSnapshot } from '$lib/search_templates/search_templates.server';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { retryTransientDashboardApiRequest } from '$lib/server/transient-api-retry';

/**
 * Fetches user indexes and available regions from the API, with automatic fallback to empty indexes and default regions on failure. Redirects to login if the session has expired.
 */
export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	let indexes: Index[] = [];
	try {
		indexes = await retryTransientDashboardApiRequest(() => api.getIndexes());
	} catch (error) {
		if (isDashboardSessionExpiredError(error)) {
			redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
	}

	const regions = await api.getInternalRegions().catch(() => DEFAULT_INTERNAL_REGIONS);
	return { indexes, regions };
};

type TemplateSeedPhase = 'settings' | 'docs' | 'synonyms' | 'rules';
const INDEX_NAME_PATTERN = /^[a-zA-Z0-9_-]+$/;
const REGION_ID_PATTERN = /^[a-z0-9-]+$/i;

function isValidIndexName(name: string): boolean {
	return INDEX_NAME_PATTERN.test(name);
}

function isValidRegionId(regionId: string): boolean {
	return REGION_ID_PATTERN.test(regionId);
}

function failTemplateSeedPhase(
	error: unknown,
	phase: TemplateSeedPhase,
	partialIndexName: string,
	fallbackMessage: string
) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) {
		return sessionFailure;
	}

	const message = customerFacingErrorMessage(error, fallbackMessage);
	return fail(400, {
		error: message,
		failedPhase: phase,
		partialIndexName
	});
}

export const actions: Actions = {
	create: async ({ request, locals }) => {
		const data = await request.formData();
		const name = (data.get('name') as string)?.trim();
		const region = (data.get('region') as string)?.trim();
		const rawTemplateId = (data.get('template_id') as string | null)?.trim();

		if (!name) return fail(400, { error: 'Index name is required' });
		if (!region) return fail(400, { error: 'Region is required' });
		if (!isValidIndexName(name)) {
			return fail(400, {
				error: 'Index name may only contain letters, numbers, underscores, and hyphens.'
			});
		}
		if (!isValidRegionId(region)) {
			return fail(400, { error: 'Region is invalid' });
		}

		const templateId = rawTemplateId || undefined;
		const templateSnapshot = templateId
			? (getIndexTemplateServerSnapshot(templateId as IndexTemplateId) as
					| ReturnType<typeof getIndexTemplateServerSnapshot>
					| undefined)
			: undefined;
		if (templateId && !templateSnapshot) {
			return fail(400, { error: 'Invalid template', failedPhase: 'invalid_template' });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await retryTransientDashboardApiRequest(() => api.createIndex(name, region));
		} catch (e) {
			const sessionFailure = mapDashboardSessionFailure(e);
			if (sessionFailure) return sessionFailure;
			if (e instanceof ApiRequestError && e.status === 409) {
				return fail(400, { error: 'Index already exists', failedPhase: 'create' });
			}
			const message = customerFacingErrorMessage(e, 'Failed to create index');
			return fail(400, { error: message, failedPhase: 'create' });
		}

		if (templateSnapshot && Object.keys(templateSnapshot.settings).length > 0) {
			try {
				await api.updateIndexSettings(name, templateSnapshot.settings);
			} catch (e) {
				return failTemplateSeedPhase(e, 'settings', name, 'Failed to apply template settings');
			}
		}

		if (templateSnapshot && templateSnapshot.documents.length > 0) {
			try {
				await api.addObjects(name, {
					requests: templateSnapshot.documents.map((doc) => ({
						action: 'addObject',
						body: doc
					}))
				});
			} catch (e) {
				return failTemplateSeedPhase(e, 'docs', name, 'Failed to seed template documents');
			}
		}

		if (templateSnapshot && templateSnapshot.synonyms.length > 0) {
			try {
				for (const synonym of templateSnapshot.synonyms) {
					await api.saveSynonym(name, synonym.objectID, synonym);
				}
			} catch (e) {
				return failTemplateSeedPhase(e, 'synonyms', name, 'Failed to seed template synonyms');
			}
		}

		if (templateSnapshot && templateSnapshot.rules.length > 0) {
			try {
				for (const rule of templateSnapshot.rules) {
					await api.saveRule(name, rule.objectID, rule);
				}
			} catch (e) {
				return failTemplateSeedPhase(e, 'rules', name, 'Failed to seed template rules');
			}
		}

		throw redirect(303, `/console/indexes/${name}`);
	},
	delete: async ({ request, locals }) => {
		const data = await request.formData();
		const name = (data.get('name') as string | null)?.trim() ?? '';
		if (!name) return fail(400, { error: 'Missing index name' });
		if (!isValidIndexName(name)) {
			return fail(400, {
				error: 'Index name may only contain letters, numbers, underscores, and hyphens.'
			});
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteIndex(name);
			return { deleted: true };
		} catch (e) {
			const sessionFailure = mapDashboardSessionFailure(e);
			if (sessionFailure) return sessionFailure;
			const message = customerFacingErrorMessage(e, 'Failed to delete index');
			return fail(400, { error: message });
		}
	}
};
