/** Shared marketing pricing constants used by the landing page pricing table. */

import type { AdminRateCard } from './admin-client';

export interface RegionPricing {
	id: string;
	display_name: string;
	multiplier: string;
}

export interface MarketingPricing {
	storage_rate_per_mb_month: string;
	cold_storage_rate_per_gb_month: string;
	free_tier_mb: number;
	region_pricing: RegionPricing[];
	minimum_spend_cents: number;
	cta_label: string;
	free_tier_promise: string;
}

export interface MarketingPricingContractSnapshot {
	storage_rate_per_mb_month: string;
	cold_storage_rate_per_gb_month: string;
	minimum_spend_cents: number;
	region_pricing: RegionPricing[];
}

type AdminRateCardComparableFields = Pick<
	AdminRateCard,
	| 'storage_rate_per_mb_month'
	| 'cold_storage_rate_per_gb_month'
	| 'minimum_spend_cents'
	| 'region_multipliers'
>;

const NO_CARD_TAGLINE = 'No credit card required';
const FREE_TIER_PROMISE = `Create your free account. ${NO_CARD_TAGLINE}.`;

export const MARKETING_PRICING: MarketingPricing = {
	storage_rate_per_mb_month: '$0.05',
	cold_storage_rate_per_gb_month: '$0.02',
	free_tier_mb: 250,
	region_pricing: [
		{ id: 'us-east-1', display_name: 'US East (Virginia)', multiplier: '1.00x' },
		{ id: 'eu-west-1', display_name: 'EU West (Ireland)', multiplier: '1.00x' },
		{ id: 'eu-central-1', display_name: 'EU Central (Germany)', multiplier: '0.70x' },
		{ id: 'eu-north-1', display_name: 'EU North (Helsinki)', multiplier: '0.75x' },
		{ id: 'us-east-2', display_name: 'US East (Ashburn)', multiplier: '0.80x' },
		{ id: 'us-west-1', display_name: 'US West (Oregon)', multiplier: '0.80x' }
	],
	minimum_spend_cents: 1000,
	cta_label: 'Get Started Free',
	free_tier_promise: FREE_TIER_PROMISE
};

function parsePricingDecimal(
	rawValue: string,
	fieldName: string,
	contextLabel: 'marketing pricing' | 'admin rate card'
): number {
	const cleaned = rawValue.trim().replace(/^\$/, '').replace(/x$/i, '');
	const parsed = Number(cleaned);
	if (!Number.isFinite(parsed)) {
		throw new Error(
			`${contextLabel} field ${fieldName} must be a decimal string, got "${rawValue}"`
		);
	}
	return parsed;
}

function formatCurrency(
	rawValue: string,
	fieldName: string,
	contextLabel: 'marketing pricing' | 'admin rate card'
): string {
	return `$${parsePricingDecimal(rawValue, fieldName, contextLabel).toFixed(2)}`;
}

function formatMultiplier(
	rawValue: string,
	fieldName: string,
	contextLabel: 'marketing pricing' | 'admin rate card'
): string {
	return `${parsePricingDecimal(rawValue, fieldName, contextLabel).toFixed(2)}x`;
}

export function pricingContractSnapshotFromMarketing(
	pricing: MarketingPricing = MARKETING_PRICING
): MarketingPricingContractSnapshot {
	return {
		storage_rate_per_mb_month: formatCurrency(
			pricing.storage_rate_per_mb_month,
			'storage_rate_per_mb_month',
			'marketing pricing'
		),
		cold_storage_rate_per_gb_month: formatCurrency(
			pricing.cold_storage_rate_per_gb_month,
			'cold_storage_rate_per_gb_month',
			'marketing pricing'
		),
		minimum_spend_cents: pricing.minimum_spend_cents,
		region_pricing: pricing.region_pricing.map((region) => ({
			id: region.id,
			display_name: region.display_name,
			multiplier: formatMultiplier(
				region.multiplier,
				`region_multipliers.${region.id}`,
				'marketing pricing'
			)
		}))
	};
}

export function pricingContractSnapshotFromAdminRateCard(
	rateCard: AdminRateCardComparableFields
): MarketingPricingContractSnapshot {
	const normalizedRegionPricing = MARKETING_PRICING.region_pricing.map((region) => {
		if (!Object.prototype.hasOwnProperty.call(rateCard.region_multipliers, region.id)) {
			throw new Error(`admin rate card missing region_multipliers.${region.id}`);
		}
		const multiplierValue = rateCard.region_multipliers[region.id];
		if (multiplierValue === undefined) {
			throw new Error(`admin rate card missing region_multipliers.${region.id}`);
		}
		return {
			id: region.id,
			display_name: region.display_name,
			multiplier: formatMultiplier(
				multiplierValue,
				`region_multipliers.${region.id}`,
				'admin rate card'
			)
		};
	});

	return {
		storage_rate_per_mb_month: formatCurrency(
			rateCard.storage_rate_per_mb_month,
			'storage_rate_per_mb_month',
			'admin rate card'
		),
		cold_storage_rate_per_gb_month: formatCurrency(
			rateCard.cold_storage_rate_per_gb_month,
			'cold_storage_rate_per_gb_month',
			'admin rate card'
		),
		minimum_spend_cents: rateCard.minimum_spend_cents,
		region_pricing: normalizedRegionPricing
	};
}
