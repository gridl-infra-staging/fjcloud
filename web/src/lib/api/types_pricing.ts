// Pricing comparison API types extracted from types.ts to keep the
// barrel file under the size-limit gate. Used by the public pricing
// page and the corresponding admin proxy endpoints.

export interface PricingCompareRequest {
	document_count: number;
	avg_document_size_bytes: number;
	search_requests_per_month: number;
	write_operations_per_month: number;
	sort_directions: number;
	num_indexes: number;
	high_availability: boolean;
}

export interface PricingCostLineItem {
	description: string;
	quantity: string;
	unit: string;
	unit_price_cents: string;
	amount_cents: number;
}

export interface PricingEstimate {
	provider: string;
	monthly_total_cents: number;
	line_items: PricingCostLineItem[];
	assumptions: string[];
	plan_name: string | null;
}

export interface PricingCompareResponse {
	workload: PricingCompareRequest;
	estimates: PricingEstimate[];
	generated_at: string;
}
