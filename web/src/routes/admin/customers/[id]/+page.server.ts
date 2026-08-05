/**
 */
import { error, fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { AdminClientError, type AdminClient } from '$lib/admin-client';
import { AUTH_COOKIE, IMPERSONATION_COOKIE, IMPERSONATION_MAX_AGE } from '$lib/config';
import { retryTransientAdminApiRequest } from '$lib/server/transient-api-retry';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';
import { authCookieOptions } from '$lib/server/auth-cookies';
import type {
	AdminAuditRow,
	AdminFleetDeployment,
	AdminRateCard,
	AdminTenantDetail,
	TenantQuotasResponse
} from '$lib/admin-client';
import type { InvoiceDetailResponse, InvoiceListItem, UsageSummaryResponse } from '$lib/api/types';
import type { Index } from '$lib/api/types/indexes';

type CustomerDetailData = {
	tenant: AdminTenantDetail;
	indexes: Array<{
		name: string;
		region: string;
		status: string;
		entries: number;
		tier: string;
	}> | null;
	deployments: AdminFleetDeployment[] | null;
	usage: UsageSummaryResponse | null;
	invoices: InvoiceListItem[] | null;
	rateCard: AdminRateCard | null;
	quotas: TenantQuotasResponse | null;
	audit: AdminAuditRow[] | null;
};

function actionError(err: unknown, fallback: string) {
	redirectIfAdminSessionAuthError(err);
	return fail(400, {
		success: false,
		error: err instanceof Error ? err.message : fallback
	});
}

/** Every privileged call on this page runs behind the durable session guard. */
async function authenticatedAdminClient(
	event: Parameters<typeof requireDurableAdminSession>[0]
): Promise<AdminClient> {
	return (await requireDurableAdminSession(event)).adminClient;
}

function loadOptional<T>(operation: () => Promise<T>): Promise<T | null> {
	return operation().catch((error) => {
		redirectIfAdminSessionAuthError(error);
		return null;
	});
}

function toCustomerDetailIndex(index: Index) {
	return {
		name: index.name,
		region: index.region,
		status: index.status,
		entries: index.entries,
		tier: index.tier
	};
}

async function runAdminAction(
	event: Parameters<typeof requireDurableAdminSession>[0],
	successMessage: string,
	fallbackMessage: string,
	operation: (client: AdminClient) => Promise<unknown>
) {
	const client = await authenticatedAdminClient(event);

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

export const load: PageServerLoad = async (event) => {
	const { params } = event;
	event.depends(`admin:customers:detail:${params.id}`);

	const client = await authenticatedAdminClient(event);

	let tenant: AdminTenantDetail;
	try {
		tenant = await retryTransientAdminApiRequest(() => client.getTenant(params.id));
	} catch (err) {
		redirectIfAdminSessionAuthError(err);
		if (err instanceof AdminClientError && err.status === 404) {
			error(404, 'Customer not found');
		}
		throw err;
	}

	const [indexes, deployments, usage, invoices, rateCard, quotas, audit] = await Promise.all([
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantIndexes(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantDeployments(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantUsage(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantInvoices(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getTenantRateCard(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getQuotas(params.id))),
		loadOptional(() => retryTransientAdminApiRequest(() => client.getCustomerAudit(params.id)))
	]);

	return {
		tenant,
		indexes: indexes?.map(toCustomerDetailIndex) ?? null,
		deployments,
		usage,
		invoices,
		rateCard,
		quotas,
		audit
	} satisfies CustomerDetailData;
};

export const actions = {
	updateQuotas: async (event) => {
		const { params } = event;
		const client = await authenticatedAdminClient(event);

		const formData = await event.request.formData();
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

	reactivate: async (event) => {
		return runAdminAction(
			event,
			'Customer reactivated',
			'Failed to reactivate customer',
			(client) => client.reactivateCustomer(event.params.id)
		);
	},

	suspend: async (event) => {
		return runAdminAction(event, 'Customer suspended', 'Failed to suspend customer', (client) =>
			client.suspendCustomer(event.params.id)
		);
	},

	syncStripe: async (event) => {
		return runAdminAction(event, 'Stripe sync complete', 'Failed to sync Stripe', (client) =>
			client.syncStripeCustomer(event.params.id)
		);
	},

	softDelete: async (event) => {
		const { params } = event;
		const client = await authenticatedAdminClient(event);

		try {
			await client.deleteTenant(params.id);
		} catch (err) {
			return actionError(err, 'Failed to delete customer');
		}

		redirect(303, '/admin/customers');
	},

	impersonate: async (event) => {
		const { params, url, cookies } = event;
		const client = await authenticatedAdminClient(event);

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

	terminateDeployment: async (event) => {
		const client = await authenticatedAdminClient(event);

		const formData = await event.request.formData();
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
	},

	viewInvoice: async (event) => {
		const { params } = event;
		const client = await authenticatedAdminClient(event);

		const formData = await event.request.formData();
		const invoiceId = formData.get('invoice_id');
		if (typeof invoiceId !== 'string' || invoiceId.trim().length === 0) {
			return fail(400, {
				success: false,
				error: 'Invoice ID is required'
			});
		}

		try {
			const invoiceDetail = await retryTransientAdminApiRequest(() =>
				client.getAdminInvoiceDetail(invoiceId)
			);
			if (invoiceDetail.customer_id !== params.id) {
				return fail(400, {
					success: false,
					error: 'Invoice does not belong to this customer'
				});
			}
			return {
				success: true,
				invoiceDetail: invoiceDetail satisfies InvoiceDetailResponse
			};
		} catch (err) {
			return actionError(err, 'Failed to load invoice detail');
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
