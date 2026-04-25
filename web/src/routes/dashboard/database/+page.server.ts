/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar22_pm_1_ayb_tenant_create_flow/fjcloud_dev/web/src/routes/dashboard/database/+page.server.ts.
 */
import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { ApiRequestError } from '$lib/api/client';
import { AYB_PLAN_OPTIONS, type AybPlanTier, type CreateAybInstanceRequest } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';

const AYB_DELETE_UNAVAILABLE_ERROR =
	'Database provisioning is currently unavailable. Please try again later.';
const AYB_CREATE_UNAVAILABLE_ERROR =
	'Database creation is currently unavailable. Please try again later.';
const AYB_CREATE_CONFLICT_ERROR = 'A database instance already exists for this account.';
const AYB_DUPLICATE_INSTANCE_ERROR =
	'Multiple active database instances were found for this account. Please contact support before continuing.';
const AYB_LOAD_UNAVAILABLE_ERROR =
	'Unable to load database instance status right now. Please try again later.';

type DatabaseLoadErrorCode = 'duplicate_instances' | 'request_failed';

function loadErrorResponse(loadError: string, loadErrorCode: DatabaseLoadErrorCode) {
	return {
		instance: null,
		provisioningUnavailable: false,
		loadError,
		loadErrorCode
	};
}

function isAybPlanTier(value: string): value is AybPlanTier {
	return AYB_PLAN_OPTIONS.some((option) => option.value === value);
}

function getTrimmedFormValue(data: FormData, key: string): string | null {
	const value = data.get(key);
	if (typeof value !== 'string') {
		return null;
	}

	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : null;
}

function deleteActionFailure(error: unknown) {
	if (error instanceof ApiRequestError) {
		return fail(error.status, {
			error: error.status === 503 ? AYB_DELETE_UNAVAILABLE_ERROR : error.message
		});
	}
	if (error instanceof Error) {
		return fail(503, { error: AYB_DELETE_UNAVAILABLE_ERROR });
	}
	return fail(500, { error: 'Failed to delete database instance' });
}

function createActionFailure(error: unknown) {
	if (error instanceof ApiRequestError) {
		if (error.status === 400) {
			return fail(400, {
				error: customerFacingErrorMessage(error, 'Invalid database instance request')
			});
		}
		if (error.status === 409) {
			return fail(409, { error: AYB_CREATE_CONFLICT_ERROR });
		}
		if (error.status === 503) {
			return fail(503, { error: AYB_CREATE_UNAVAILABLE_ERROR });
		}
		return fail(500, { error: 'Failed to create database instance' });
	}
	if (error instanceof Error) {
		return fail(503, { error: AYB_CREATE_UNAVAILABLE_ERROR });
	}
	return fail(500, { error: 'Failed to create database instance' });
}

export const load: PageServerLoad = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);
	try {
		const instances = await api.getAybInstances();
		if (instances.length > 1) {
			return loadErrorResponse(AYB_DUPLICATE_INSTANCE_ERROR, 'duplicate_instances');
		}

		const instance = instances.length === 1 ? instances[0] : null;
		return {
			instance,
			provisioningUnavailable: instance === null
		};
	} catch (error) {
		if (error instanceof Error) {
			return loadErrorResponse(AYB_LOAD_UNAVAILABLE_ERROR, 'request_failed');
		}
		throw error;
	}
};

export const actions: Actions = {
	create: async ({ request, locals }) => {
		const data = await request.formData();
		const name = getTrimmedFormValue(data, 'name');
		const slug = getTrimmedFormValue(data, 'slug');
		const plan = getTrimmedFormValue(data, 'plan');

		if (!name || !slug || !plan) {
			return fail(400, { error: 'Name, slug, and plan are required' });
		}
		if (!isAybPlanTier(plan)) {
			return fail(400, { error: 'Invalid database plan' });
		}

		const api = createApiClient(locals.user?.token);
		try {
			const body: CreateAybInstanceRequest = { name, slug, plan };
			await api.createAybInstance(body);
			return { created: true };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return createActionFailure(error);
		}
	},

	delete: async ({ request, locals }) => {
		const data = await request.formData();
		const id = getTrimmedFormValue(data, 'id');

		if (!id) {
			return fail(400, { error: 'Missing database instance ID' });
		}

		const api = createApiClient(locals.user?.token);
		try {
			await api.deleteAybInstance(id);
			return { deleted: true };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return deleteActionFailure(error);
		}
	}
};
