// Usage summary, invoice, estimate, Stripe portal, and billing upgrade types.

export interface RegionUsageSummary {
	region: string;
	search_requests: number;
	write_operations: number;
	avg_storage_gb: number;
	avg_document_count: number;
}

export interface UsageSummaryResponse {
	month: string;
	total_search_requests: number;
	total_write_operations: number;
	avg_storage_gb: number;
	avg_document_count: number;
	by_region: RegionUsageSummary[];
}

export interface DailyUsageEntry {
	date: string;
	region: string;
	search_requests: number;
	write_operations: number;
	storage_gb: number;
	document_count: number;
}

export interface InvoiceListItem {
	id: string;
	period_start: string;
	period_end: string;
	subtotal_cents: number;
	total_cents: number;
	status: string;
	minimum_applied: boolean;
	created_at: string;
}

export interface LineItemResponse {
	id: string;
	description: string;
	quantity: string;
	unit: string;
	unit_price_cents: string;
	amount_cents: number;
	region: string;
}

export interface InvoiceDetailResponse {
	id: string;
	customer_id: string;
	period_start: string;
	period_end: string;
	subtotal_cents: number;
	total_cents: number;
	tax_cents: number;
	currency: string;
	status: string;
	minimum_applied: boolean;
	stripe_invoice_id: string | null;
	hosted_invoice_url: string | null;
	pdf_url: string | null;
	line_items: LineItemResponse[];
	created_at: string;
	finalized_at: string | null;
	paid_at: string | null;
}

export interface EstimateLineItem {
	description: string;
	quantity: string;
	unit: string;
	unit_price_cents: string;
	amount_cents: number;
	region: string;
}

export interface EstimatedBillResponse {
	month: string;
	subtotal_cents: number;
	total_cents: number;
	line_items: EstimateLineItem[];
	minimum_applied: boolean;
}

export interface SetupIntentResponse {
	client_secret: string;
}

export interface CreateBillingPortalSessionRequest {
	return_url: string;
}

export interface CreateBillingPortalSessionResponse {
	portal_url: string;
}

export interface PaymentMethod {
	id: string;
	card_brand: string;
	last4: string;
	exp_month: number;
	exp_year: number;
	is_default: boolean;
}

export interface BillingUpgradeResponse {
	billing_plan: 'free' | 'shared';
	subscription_cycle_anchor_at: string;
	stripe_invoice_id: string;
	activation_amount_cents: number;
}
