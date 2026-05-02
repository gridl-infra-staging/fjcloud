/**
 */
import { env } from '$env/dynamic/private';
import { getApiBaseUrl } from '$lib/config';
import type { InvoiceDetailResponse, InvoiceListItem, UsageSummaryResponse } from '$lib/api/types';
import { BaseClient } from '$lib/api/base-client';

export interface AdminFleetDeployment {
	id: string;
	customer_id: string;
	region: string;
	vm_provider: string;
	status: string;
	health_status: string;
	flapjack_url: string | null;
	created_at: string;
	last_health_check_at?: string | null;
}

export interface HealthCheckResponse {
	id: string;
	health_status: string;
	last_health_check_at: string;
}

export interface AdminProviderSummary {
	provider: string;
	region_count: number;
	regions: string[];
	vm_count: number;
}

export type BillingHealthStatus = 'green' | 'yellow' | 'red' | 'grey';

export interface AdminTenant {
	id: string;
	name: string;
	email: string;
	status: string;
	billing_plan: string;
	last_accessed_at: string | null;
	overdue_invoice_count: number;
	billing_health: BillingHealthStatus;
	created_at: string;
	updated_at: string;
}

export interface AdminTenantDetail extends AdminTenant {
	stripe_customer_id?: string | null;
}

export interface AdminRateCard {
	id: string;
	name: string;
	storage_rate_per_mb_month: string;
	cold_storage_rate_per_gb_month: string;
	object_storage_rate_per_gb_month: string;
	object_storage_egress_rate_per_gb: string;
	region_multipliers: Record<string, string>;
	minimum_spend_cents: number;
	shared_minimum_spend_cents: number;
	has_override: boolean;
	override_fields: Record<string, unknown>;
}

export interface AdminActionResponse {
	message: string;
	[key: string]: unknown;
}

export interface CreateTokenResponse {
	token: string;
	expires_at: string;
}

export interface BatchBillingResult {
	customer_id: string;
	status: string;
	invoice_id: string | null;
	reason: string | null;
}

export interface BatchBillingResponse {
	month: string;
	invoices_created: number;
	invoices_skipped: number;
	results: BatchBillingResult[];
}

export type AlertSeverity = 'info' | 'warning' | 'critical';

export interface AdminAlertRecord {
	id: string;
	severity: AlertSeverity;
	title: string;
	message: string;
	metadata: Record<string, unknown>;
	delivery_status: string;
	created_at: string;
}

export type MigrationStatus =
	| 'pending'
	| 'replicating'
	| 'cutting_over'
	| 'completed'
	| 'failed'
	| 'rolled_back';

export interface AdminMigration {
	id: string;
	index_name: string;
	customer_id: string;
	source_vm_id: string;
	dest_vm_id: string;
	status: MigrationStatus;
	requested_by: string;
	started_at: string;
	completed_at: string | null;
	error: string | null;
	metadata: Record<string, unknown>;
}

export interface TriggerMigrationRequest {
	index_name: string;
	dest_vm_id: string;
}

export interface TriggerMigrationResponse {
	migration_id: string;
	status: string;
}

export interface VmTenant {
	customer_id: string;
	tenant_id: string;
	deployment_id: string;
	vm_id: string | null;
	tier: string;
	resource_quota: Record<string, unknown>;
	created_at: string;
}

/** A single VM from the inventory list (GET /admin/vms). */
export interface VmInventoryItem {
	id: string;
	region: string;
	provider: string;
	hostname: string;
	flapjack_url: string;
	capacity: Record<string, number>;
	current_load: Record<string, number>;
	status: string;
	created_at: string;
	updated_at: string;
}

/** Response from POST /admin/vms/{id}/kill (local-mode only). */
export interface KillVmResponse {
	vm_id: string;
	region: string;
	port: number;
	status: string;
}

/**
 * VM detail with tenant assignment and provider linkage.
 */
export interface VmDetail {
	vm: {
		id: string;
		region: string;
		provider: string;
		provider_vm_id?: string | null;
		hostname: string;
		flapjack_url: string;
		capacity: Record<string, number>;
		current_load: Record<string, number>;
		status: string;
		created_at: string;
		updated_at: string;
	};
	tenants: VmTenant[];
}

export interface QuotaValues {
	max_query_rps: number;
	max_write_rps: number;
	max_storage_bytes: number;
	max_indexes: number;
}

export interface TenantIndexQuota {
	index_name: string;
	effective: QuotaValues;
	override: Record<string, unknown>;
}

export interface TenantQuotasResponse {
	defaults: QuotaValues;
	indexes: TenantIndexQuota[];
}

export interface AdminReplicaEntry {
	id: string;
	customer_id: string;
	tenant_id: string;
	replica_region: string;
	status: string;
	lag_ops: number;
	primary_vm_id: string;
	primary_vm_hostname: string;
	primary_vm_region: string;
	replica_vm_id: string;
	replica_vm_hostname: string;
	created_at: string;
	updated_at: string;
}

export interface AdminAuditRow {
	id: string;
	actor_id: string;
	action: string;
	target_tenant_id: string | null;
	metadata: unknown;
	created_at: string;
}

export interface ColdIndexEntry {
	customer_id: string;
	customer_name?: string;
	tenant_id: string;
	snapshot_id: string | null;
	size_bytes: number;
	status: string;
	object_key: string | null;
	cold_since: string | null;
	last_accessed_at: string | null;
}

export interface UpdateQuotasRequest {
	max_query_rps?: number;
	max_write_rps?: number;
	max_storage_bytes?: number;
	max_indexes?: number;
}

export class AdminClientError extends Error {
	readonly status: number;

	constructor(message: string, status: number) {
		super(message);
		this.name = 'AdminClientError';
		this.status = status;
	}
}

const ADMIN_RATE_LIMIT_MAX_RETRIES = 2;
const ADMIN_RATE_LIMIT_FALLBACK_DELAY_MS = 1_000;
const ADMIN_RATE_LIMIT_MAX_DELAY_MS = 5_000;

export class AdminClient extends BaseClient {
	private readonly adminKey: string;

	constructor(baseUrl: string, adminKey: string) {
		super(baseUrl);
		this.adminKey = adminKey;
	}

	protected authHeaders(): Record<string, string> {
		return { 'X-Admin-Key': this.adminKey };
	}

	protected async handleErrorResponse(res: Response): Promise<never> {
		let message = 'Admin API request failed';
		try {
			const body = (await res.json()) as { error?: string };
			if (body?.error) message = body.error;
		} catch {
			// keep fallback message if response body isn't JSON
		}
		throw new AdminClientError(message, res.status);
	}

	private async sleep(ms: number): Promise<void> {
		await new Promise((resolve) => setTimeout(resolve, ms));
	}

	private retryDelayMs(res: Response): number {
		const retryAfterHeader = res.headers.get('Retry-After');
		const retryAfterSeconds = retryAfterHeader ? Number.parseInt(retryAfterHeader, 10) : NaN;
		if (Number.isFinite(retryAfterSeconds) && retryAfterSeconds > 0) {
			return Math.min(retryAfterSeconds * 1_000, ADMIN_RATE_LIMIT_MAX_DELAY_MS);
		}
		return ADMIN_RATE_LIMIT_FALLBACK_DELAY_MS;
	}

	private async adminRequest<T>(path: string, init?: RequestInit): Promise<T> {
		const url = `${this.baseUrl}${path}`;

		for (let attempt = 0; ; attempt += 1) {
			const res = await this.fetchFn(url, {
				...init,
				headers: {
					'Content-Type': 'application/json',
					...this.authHeaders(),
					...(init?.headers ?? {})
				}
			});

			if (res.status === 429 && attempt < ADMIN_RATE_LIMIT_MAX_RETRIES) {
				await this.sleep(this.retryDelayMs(res));
				continue;
			}

			if (!res.ok) {
				await this.handleErrorResponse(res);
			}

			if (res.status === 204) {
				return undefined as T;
			}

			return res.json() as Promise<T>;
		}
	}

	private get<T>(path: string): Promise<T> {
		return this.adminRequest<T>(path);
	}

	private post<T>(path: string, body?: unknown): Promise<T> {
		return this.adminRequest<T>(path, {
			method: 'POST',
			body: body === undefined ? undefined : JSON.stringify(body)
		});
	}

	private put<T>(path: string, body: unknown): Promise<T> {
		return this.adminRequest<T>(path, {
			method: 'PUT',
			body: JSON.stringify(body)
		});
	}

	private deleteRequest(path: string): Promise<void> {
		return this.adminRequest<void>(path, {
			method: 'DELETE'
		});
	}

	private withQuery(path: string, params: URLSearchParams): string {
		const query = params.toString();
		return query ? `${path}?${query}` : path;
	}

	getFleet(): Promise<AdminFleetDeployment[]> {
		return this.get<AdminFleetDeployment[]>('/admin/fleet');
	}

	getProviders(): Promise<AdminProviderSummary[]> {
		return this.get<AdminProviderSummary[]>('/admin/providers');
	}

	getTenants(): Promise<AdminTenant[]> {
		return this.get<AdminTenant[]>('/admin/tenants');
	}

	getTenant(id: string): Promise<AdminTenantDetail> {
		return this.get<AdminTenantDetail>(`/admin/tenants/${id}`);
	}

	getTenantDeployments(id: string): Promise<AdminFleetDeployment[]> {
		return this.get<AdminFleetDeployment[]>(`/admin/tenants/${id}/deployments`);
	}

	getTenantUsage(id: string, month?: string): Promise<UsageSummaryResponse> {
		const monthQuery = month ? `?month=${encodeURIComponent(month)}` : '';
		return this.get<UsageSummaryResponse>(`/admin/tenants/${id}/usage${monthQuery}`);
	}

	getTenantInvoices(id: string): Promise<InvoiceListItem[]> {
		return this.get<InvoiceListItem[]>(`/admin/tenants/${id}/invoices`);
	}

	getTenantRateCard(id: string): Promise<AdminRateCard> {
		return this.get<AdminRateCard>(`/admin/tenants/${id}/rate-card`);
	}

	getCustomerAudit(id: string): Promise<AdminAuditRow[]> {
		return this.get<AdminAuditRow[]>(`/admin/customers/${id}/audit`);
	}

	healthCheckDeployment(id: string): Promise<HealthCheckResponse> {
		return this.post<HealthCheckResponse>(`/admin/deployments/${id}/health-check`);
	}

	syncStripeCustomer(id: string): Promise<AdminActionResponse> {
		return this.post<AdminActionResponse>(`/admin/customers/${id}/sync-stripe`);
	}

	reactivateCustomer(id: string): Promise<AdminActionResponse> {
		return this.post<AdminActionResponse>(`/admin/customers/${id}/reactivate`);
	}

	suspendCustomer(id: string): Promise<AdminActionResponse> {
		return this.post<AdminActionResponse>(`/admin/customers/${id}/suspend`);
	}

	/**
	 * Mint a JWT for a customer via the admin API.
	 *
	 * `purpose` is an optional discriminator the server uses to decide whether
	 * to write an `audit_log` row. The `?/impersonate` form action passes
	 * `'impersonation'` so customer-trust review (T1.4 view) can show a
	 * paper-trail of operator impersonation events. Routine token mints
	 * (testing, ops scripts) leave `purpose` unset so audit_log stays
	 * signal-dense.
	 */
	createToken(
		customerId: string,
		expiresInSecs?: number,
		purpose?: string
	): Promise<CreateTokenResponse> {
		const body: Record<string, unknown> = { customer_id: customerId };
		if (expiresInSecs !== undefined) {
			body.expires_in_secs = expiresInSecs;
		}
		if (purpose !== undefined) {
			body.purpose = purpose;
		}
		return this.post<CreateTokenResponse>('/admin/tokens', body);
	}

	deleteTenant(id: string): Promise<void> {
		return this.deleteRequest(`/admin/tenants/${id}`);
	}

	terminateDeployment(id: string): Promise<void> {
		return this.deleteRequest(`/admin/deployments/${id}`);
	}

	runBatchBilling(month: string): Promise<BatchBillingResponse> {
		return this.post<BatchBillingResponse>('/admin/billing/run', { month });
	}

	finalizeInvoice(id: string): Promise<InvoiceDetailResponse> {
		return this.post<InvoiceDetailResponse>(`/admin/invoices/${id}/finalize`);
	}

	getAlerts(limit = 100, severity?: AlertSeverity): Promise<AdminAlertRecord[]> {
		const params = new URLSearchParams();
		params.set('limit', String(limit));
		if (severity) {
			params.set('severity', severity);
		}
		return this.get<AdminAlertRecord[]>(this.withQuery('/admin/alerts', params));
	}

	getMigrations(params?: { status?: string; limit?: number }): Promise<AdminMigration[]> {
		const query = new URLSearchParams();
		if (params?.status) {
			query.set('status', params.status);
		}
		if (typeof params?.limit === 'number') {
			query.set('limit', String(params.limit));
		}
		return this.get<AdminMigration[]>(this.withQuery('/admin/migrations', query));
	}

	triggerMigration(req: TriggerMigrationRequest): Promise<TriggerMigrationResponse> {
		return this.post<TriggerMigrationResponse>('/admin/migrations', req);
	}

	/** List all active VMs from the inventory (GET /admin/vms). */
	listVms(): Promise<VmInventoryItem[]> {
		return this.get<VmInventoryItem[]>('/admin/vms');
	}

	getVmDetail(id: string): Promise<VmDetail> {
		return this.get<VmDetail>(`/admin/vms/${id}`);
	}

	/** Kill the local Flapjack process for a VM (POST /admin/vms/{id}/kill).
	 *  Local-mode only — returns 400 for non-localhost URLs. */
	killVm(id: string): Promise<KillVmResponse> {
		return this.post<KillVmResponse>(`/admin/vms/${id}/kill`);
	}

	getQuotas(tenantId: string): Promise<TenantQuotasResponse> {
		return this.get<TenantQuotasResponse>(`/admin/tenants/${tenantId}/quotas`);
	}

	updateQuotas(tenantId: string, quotas: UpdateQuotasRequest): Promise<TenantQuotasResponse> {
		return this.put<TenantQuotasResponse>(`/admin/tenants/${tenantId}/quotas`, quotas);
	}

	getReplicas(params?: { status?: string }): Promise<AdminReplicaEntry[]> {
		const query = new URLSearchParams();
		if (params?.status) {
			query.set('status', params.status);
		}
		return this.get<AdminReplicaEntry[]>(this.withQuery('/admin/replicas', query));
	}

	getColdIndexes(): Promise<ColdIndexEntry[]> {
		return this.get<ColdIndexEntry[]>('/admin/cold');
	}

	restoreColdIndex(snapshotId: string): Promise<{ restore_job_id: string; status: string }> {
		return this.post<{ restore_job_id: string; status: string }>(
			`/admin/cold/${snapshotId}/restore`
		);
	}
}

export function createAdminClient(): AdminClient {
	const adminKey = env.ADMIN_KEY;
	if (!adminKey) {
		throw new Error('ADMIN_KEY is required for admin client requests');
	}
	return new AdminClient(getApiBaseUrl(), adminKey);
}
