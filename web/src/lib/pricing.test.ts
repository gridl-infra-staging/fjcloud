import { describe, it, expect } from 'vitest';
import type { AdminRateCard } from './admin-client';
import {
	MARKETING_PRICING,
	pricingContractSnapshotFromAdminRateCard,
	pricingContractSnapshotFromMarketing
} from './pricing';
import { marketingPricingPageData } from '../routes/marketing_pricing';
import { load as pricingPageLoad } from '../routes/pricing/+page';

describe('pricing constants', () => {
	describe('MARKETING_PRICING', () => {
		it('has per-MB hot storage rate and no legacy search/write rates', () => {
			expect(MARKETING_PRICING.storage_rate_per_mb_month).toBe('$0.05');
			expect(MARKETING_PRICING.cold_storage_rate_per_gb_month).toBe('$0.02');
			// Legacy multi-dimension fields must not exist
			expect(MARKETING_PRICING).not.toHaveProperty('search_rate_per_1k');
			expect(MARKETING_PRICING).not.toHaveProperty('write_rate_per_1k');
			expect(MARKETING_PRICING).not.toHaveProperty('storage_rate_per_gb_month');
		});

		it('has $10 minimum spend (1000 cents)', () => {
			expect(MARKETING_PRICING.minimum_spend_cents).toBe(1000);
		});

		it('has 250 MB free tier', () => {
			expect(MARKETING_PRICING.free_tier_mb).toBe(250);
		});

		it('has CTA label for free-tier entry', () => {
			expect(MARKETING_PRICING.cta_label).toBe('Get Started Free');
		});

		it('has a shared free-tier promise used across public entry routes', () => {
			expect(MARKETING_PRICING.free_tier_promise).toBe(
				'Create your free account. No credit card required.'
			);
		});

		it('has six regions', () => {
			expect(MARKETING_PRICING.region_pricing).toHaveLength(6);
		});

		it('region entries have id, display_name, and multiplier', () => {
			const first = MARKETING_PRICING.region_pricing[0];
			expect(first).toHaveProperty('id');
			expect(first).toHaveProperty('display_name');
			expect(first).toHaveProperty('multiplier');
		});

		it('has exact region values for the full region set', () => {
			const regions = MARKETING_PRICING.region_pricing;
			expect(regions).toEqual([
				{ id: 'us-east-1', display_name: 'US East (Virginia)', multiplier: '1.00x' },
				{ id: 'eu-west-1', display_name: 'EU West (Ireland)', multiplier: '1.00x' },
				{ id: 'eu-central-1', display_name: 'EU Central (Germany)', multiplier: '0.70x' },
				{ id: 'eu-north-1', display_name: 'EU North (Helsinki)', multiplier: '0.75x' },
				{ id: 'us-east-2', display_name: 'US East (Ashburn)', multiplier: '0.80x' },
				{ id: 'us-west-1', display_name: 'US West (Oregon)', multiplier: '0.80x' }
			]);
		});

		it('keeps marketing route and /pricing load contract pinned to the same MARKETING_PRICING reference', async () => {
			const marketingPageData = marketingPricingPageData();
			const pricingLoadData = await pricingPageLoad({} as never);
			expect(pricingLoadData).toBeDefined();
			if (!pricingLoadData) {
				throw new Error('pricing page load returned no data');
			}

			expect(marketingPageData.pricing).toBe(MARKETING_PRICING);
			expect(pricingLoadData.pricing).toBe(MARKETING_PRICING);
			expect(pricingLoadData.pricing).toBe(marketingPageData.pricing);
		});

		it('normalizes backend admin rate-card JSON into the same pricing contract snapshot', () => {
			const backendRateCard: AdminRateCard = {
				id: '6fb8de77-ea6e-45c6-ac77-1de2f91f3201',
				name: 'Default',
				storage_rate_per_mb_month: '0.050',
				cold_storage_rate_per_gb_month: '0.02',
				object_storage_rate_per_gb_month: '0.03',
				object_storage_egress_rate_per_gb: '0.09',
				region_multipliers: {
					'us-east-1': '1',
					'eu-west-1': '1.00',
					'eu-central-1': '0.7',
					'eu-north-1': '0.7500',
					'us-east-2': '0.8',
					'us-west-1': '0.80'
				},
				minimum_spend_cents: 1000,
				shared_minimum_spend_cents: 500,
				has_override: false,
				override_fields: {}
			};

			const marketingSnapshot = pricingContractSnapshotFromMarketing(MARKETING_PRICING);
			const adminSnapshot = pricingContractSnapshotFromAdminRateCard(backendRateCard);

			expect(adminSnapshot).toEqual(marketingSnapshot);
		});
	});
});
