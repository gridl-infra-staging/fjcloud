/**
 * Landing-page pricing helpers.
 *
 * Flapjack Cloud estimates come from the backend /pricing/compare endpoint.
 * This module only provides stable request defaults and display helpers.
 */
import type { PricingCompareRequest } from '$lib/api/types';
import { formatCents } from '$lib/format';
export type LandingPricingInputs = PricingCompareRequest;

const DEFAULT_WORKLOAD: PricingCompareRequest = {
	document_count: 100_000,
	avg_document_size_bytes: 2048,
	search_requests_per_month: 1_000_000,
	write_operations_per_month: 50_000,
	sort_directions: 2,
	num_indexes: 1,
	high_availability: false
};

export function createDefaultLandingPricingInputs(): LandingPricingInputs {
	return { ...DEFAULT_WORKLOAD };
}

export function toPricingCompareRequest(inputs: LandingPricingInputs): PricingCompareRequest {
	return { ...inputs };
}

export function formatLandingCurrency(cents: number): string {
	return formatCents(cents);
}
