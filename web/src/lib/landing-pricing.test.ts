import { describe, expect, it } from 'vitest';
import {
	createDefaultLandingPricingInputs,
	formatLandingCurrency,
	toPricingCompareRequest
} from './landing-pricing';

describe('landing-pricing helpers', () => {
	it('provides stable workload defaults matching the backend compare contract', () => {
		const defaults = createDefaultLandingPricingInputs();

		expect(defaults.document_count).toBe(100_000);
		expect(defaults.avg_document_size_bytes).toBe(2048);
		expect(defaults.search_requests_per_month).toBe(1_000_000);
		expect(defaults.write_operations_per_month).toBe(50_000);
		expect(defaults.sort_directions).toBe(2);
		expect(defaults.num_indexes).toBe(1);
		expect(defaults.high_availability).toBe(false);
		expect(defaults).not.toHaveProperty('region_id');
	});

	it('formats cents as USD currency display', () => {
		expect(formatLandingCurrency(123_456)).toBe('$1,234.56');
		expect(formatLandingCurrency(200)).toBe('$2.00');
	});

	it('serializes the exact backend compare payload shape', () => {
		const defaults = createDefaultLandingPricingInputs();
		expect(toPricingCompareRequest(defaults)).toEqual(defaults);
	});

	it('does not export buildGriddleEstimate — Flapjack Cloud estimates come from the backend', async () => {
		const exports = await import('./landing-pricing');
		expect(exports).not.toHaveProperty('buildGriddleEstimate');
	});

	it('does not export BYTES_PER_GB — no longer needed without local estimate synthesis', async () => {
		const exports = await import('./landing-pricing');
		expect(exports).not.toHaveProperty('BYTES_PER_GB');
	});
});
