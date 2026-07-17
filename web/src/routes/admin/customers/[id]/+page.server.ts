/**
 */
import { error, fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { AdminClientError, createAdminClient } from '$lib/admin-client';
import { AUTH_COOKIE, IMPERSONATION_COOKIE, IMPERSONATION_MAX_AGE } from '$lib/config';
import { retryTransientAdminApiRequest } from '$lib/server/transient-api-retry';
import {
	ADMIN_SESSION_COOKIE,
	getAdminSession,
	purgeExpiredAdminSessions
} from '$lib/server/admin-session';
import { authCookieOptions } from '$lib/server/auth-cookies';
import { privateEnvValue, type RuntimeEnv } from '$lib/server/runtime-env';
import type {
	AdminAuditRow,
	AdminFleetDeployment,
	AdminRateCard,
	AdminTenantDetail,
	TenantQuotasResponse
} from '$lib/admin-client';
import type { InvoiceListItem, UsageSummaryResponse } from '$lib/api/types';

type CustomerDetailData = {
	tenant: AdminTenantDetail;
	indexes: Array<{ name: string; region: string; status: string; entries: number }> | null;
	deployments: AdminFleetDeployment[] | null;
	usage: UsageSummaryResponse | null;
	invoices: InvoiceListItem[] | null;
	rateCard: AdminRateCard | null;
	quotas: TenantQuotasResponse | null;
	audit: AdminAuditRow[] | null;
};

type AdminCookieReader = { get(name: string): string | undefined };
type AdminActionContext = {
	fetch: typeof globalThis.fetch;
	cookies: AdminCookieReader;
	runtimeEnv?: RuntimeEnv;
};

function adminClient(f: typeof globalThis.fetch, runtimeEnv?: RuntimeEnv) {
	const client = createAdminClient(undefined, runtimeEnv);
	client.setFetch(f);
	return client;
}

function actionError(err: unknown, fallback: string) {
	return fail(400, {
		success: false,
		error: err instanceof Error ? err.message : fallback
	});
}

function authenticatedAdminClient(
	fetch: typeof globalThis.fetch,
	cookies: AdminCookieReader,
	runtimeEnv?: RuntimeEnv
) {
	requireAdminSession(cookies, runtimeEnv);
	return adminClient(fetch, runtimeEnv);
}

function loadOptional<T>(operation: () => Promise<T>): Promise<T | null> {
	return operation().catch(() => null);
}

async function runAdminAction(
	context: AdminActionContext,
	successMessage: string,
	fallbackMessage: string,
	operation: (client: ReturnType<typeof adminClient>) => Promise<unknown>
) {
	const client = authenticatedAdminClient(context.fetch, context.cookies, context.runtimeEnv);

	try {
		await retryTransientAdminApiRequest(() => operation(client));
		return {
			success: true,
			message: successMessage
		};
	} catch (err) {
		return actionError(err, fallbackMessage);
	}
}

export const load: PageServerLoad = async ({ fetch, params, depends, platform }) => {
	depends(`admin:customers:detail:${params.id}`);

	const client = adminClient(fetch, platform?.env);

	let tenant: AdminTenantDetail;
	try {
		tenant = await retryTransientAdminApiRequest(() => client.getTenant(params.id));
	} catch (err) {
		if (err instanceof AdminClientError && err.status === 404) {
			error(404, 'Customer not found');
		}
		throw err;
	}

	const [deployments, usage, invoices, rateCard, quotas, audit] = await Promise.all([
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantDeployments(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantUsage(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantInvoices(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantRateCard(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getQuotas(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getCustomerAudit(params.id)))
	]);

	return {
		tenant,
		indexes: null as CustomerDetailData['indexes'],
		deployments,
		usage,
		invoices,
		rateCard,
		quotas,
		audit
	} satisfies CustomerDetailData;
};

export const actions = {
	updateQuotas: async ({ request, params, fetch, cookies, platform }) => {
		const client = authenticatedAdminClient(fetch, cookies, platform?.env);

		const formData = await request.formData();
		const maxQueryRps = _parseOptionalU32(formData.get('max_query_rps'));
		const maxWriteRps = _parseOptionalU32(formData.get('max_write_rps'));
		const maxStorageBytes = _parseOptionalU32(formData.get('max_storage_bytes'));
		const maxIndexes = _parseOptionalU32(formData.get('max_indexes'));

		if (
			maxQueryRps === undefined &&
			maxWriteRps === undefined &&
			maxStorageBytes === undefined &&
			maxIndexes === undefined
		) {
			return fail(400, {
				success: false,
				error: 'At least one quota value is required'
			});
		}

		try {
			await retryTransientAdminApiRequest(() =>
				client.updateQuotas(params.id, {
					max_query_rps: maxQueryRps,
					max_write_rps: maxWriteRps,
					max_storage_bytes: maxStorageBytes,
					max_indexes: maxIndexes
				})
			);

			return {
				success: true,
				message: 'Quotas updated'
			};
		} catch (err) {
			return actionError(err, 'Failed to update quotas');
		}
	},

	reactivate: async ({ params, fetch, cookies, platform }) => {
		return runAdminAction(
			{ fetch, cookies, runtimeEnv: platform?.env },
			'Customer reactivated',
			'Failed to reactivate customer',
			(client) => client.reactivateCustomer(params.id)
		);
	},

	suspend: async ({ params, fetch, cookies, platform }) => {
		return runAdminAction(
			{ fetch, cookies, runtimeEnv: platform?.env },
			'Customer suspended',
			'Failed to suspend customer',
			(client) => client.suspendCustomer(params.id)
		);
	},

	syncStripe: async ({ params, fetch, cookies, platform }) => {
		return runAdminAction(
			{ fetch, cookies, runtimeEnv: platform?.env },
			'Stripe sync complete',
			'Failed to sync Stripe',
			(client) => client.syncStripeCustomer(params.id)
		);
	},

	softDelete: async ({ params, fetch, cookies, platform }) => {
		const client = authenticatedAdminClient(fetch, cookies, platform?.env);

		try {
			await client.deleteTenant(params.id);
		} catch (err) {
			return actionError(err, 'Failed to delete customer');
		}

		redirect(303, '/admin/customers');
	},

	impersonate: async ({ params, fetch, url, cookies, platform }) => {
		const client = authenticatedAdminClient(fetch, cookies, platform?.env);

		try {
			// Pass purpose='impersonation' so the API writes an audit_log row.
			// Without this, impersonation events look indistinguishable from
			// routine admin token mints in T1.4's per-customer audit view —
			// the whole point of the paper trail.
			const { token } = await client.createToken(params.id, IMPERSONATION_MAX_AGE, 'impersonation');
			const cookieOptions = authCookieOptions(url, IMPERSONATION_MAX_AGE, '/');
			cookies.set(AUTH_COOKIE, token, cookieOptions);
			cookies.set(IMPERSONATION_COOKIE, `/admin/customers/${params.id}`, cookieOptions);
		} catch (err) {
			return actionError(err, 'Failed to create impersonation token');
		}

		redirect(303, '/console');
	},

	terminateDeployment: async ({ request, fetch, cookies, platform }) => {
		const client = authenticatedAdminClient(fetch, cookies, platform?.env);

		const formData = await request.formData();
		const deploymentId = formData.get('deployment_id');
		if (typeof deploymentId !== 'string' || deploymentId.trim().length === 0) {
			return fail(400, {
				success: false,
				error: 'Deployment ID is required'
			});
		}

		try {
			await retryTransientAdminApiRequest(() => client.terminateDeployment(deploymentId));
			return {
				success: true,
				message: 'Deployment terminated'
			};
		} catch (err) {
			return actionError(err, 'Failed to terminate deployment');
		}
	}
} satisfies Actions;

export function _parseOptionalU32(value: FormDataEntryValue | null): number | undefined {
	if (typeof value !== 'string') {
		return undefined;
	}
	const trimmed = value.trim();
	if (trimmed.length === 0) {
		return undefined;
	}
	const parsed = Number.parseInt(trimmed, 10);
	if (!Number.isFinite(parsed) || parsed <= 0) {
		return undefined;
	}
	return parsed;
}

export const _parseOptionalU64 = _parseOptionalU32;

function requireAdminSession(cookies: AdminCookieReader, runtimeEnv?: RuntimeEnv): void {
	purgeExpiredAdminSessions();

	if (
		!getAdminSession(
			cookies.get(ADMIN_SESSION_COOKIE),
			privateEnvValue('ADMIN_KEY', { env: runtimeEnv })
		)
	) {
		redirect(303, '/admin/login');
	}
}
