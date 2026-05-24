import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import type { Component } from 'svelte';
import { formatCents } from '$lib/format';
import { MARKETING_PRICING, sharedPlanMinimumMonthlyLabel } from '$lib/pricing';
import PricingLayoutTestWrapper from './pricing_layout_test_wrapper.svelte';

const { pageState } = vi.hoisted(() => ({
	pageState: { url: new URL('http://localhost/pricing') }
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

function expectedFreeTierUpgradeCopy(sharedMinimumSpendCents: number): string {
	return `Free for hobby projects and evaluation. Upgrade to a paid plan (${sharedPlanMinimumMonthlyLabel(sharedMinimumSpendCents)}/month minimum) to lift the caps.`;
}

afterEach(cleanup);

const EXPECTED_REGIONS = MARKETING_PRICING.region_pricing.map((region) => region.display_name);
const PRICING_ROUTE_COMPONENT_PATH = './+page.svelte';
const PRICING_ROUTE_MODULE_IDENTIFIERS = ['./+page.svelte', '/routes/pricing/+page.svelte'];
type PricingPageProps = { data: { pricing: typeof MARKETING_PRICING } };
const US_INTEGER_FORMATTER = new Intl.NumberFormat('en-US');

function isPricingRouteModuleIdentifier(value: string): boolean {
	const normalizedValue = value.toLowerCase();
	return PRICING_ROUTE_MODULE_IDENTIFIERS.some((identifier) =>
		normalizedValue.includes(identifier)
	);
}

function isMissingPricingRouteModule(error: unknown): boolean {
	if (!(error instanceof Error)) {
		return false;
	}

	const message = error.message;
	const lowerMessage = message.toLowerCase();
	const missingModuleSpecifier =
		message.match(/cannot find module\s+['"]([^'"]+)['"]/i)?.[1] ??
		message.match(/cannot find module\s+(\S+)/i)?.[1] ??
		'';
	const cannotFindModule =
		lowerMessage.includes('cannot find module') &&
		isPricingRouteModuleIdentifier(missingModuleSpecifier);
	const failedUrlSpecifier =
		message.match(/failed to load url\s+(.+?)\s+\(resolved id:/i)?.[1]?.trim() ?? '';
	const viteMissingUrl =
		lowerMessage.includes('failed to load url') &&
		lowerMessage.includes('does the file exist') &&
		isPricingRouteModuleIdentifier(failedUrlSpecifier);

	return cannotFindModule || viteMissingUrl;
}

async function renderPricingPage(pricing = MARKETING_PRICING): Promise<void> {
	let module: unknown;
	try {
		module = await import(/* @vite-ignore */ PRICING_ROUTE_COMPONENT_PATH);
	} catch (error) {
		// Stage 2 intentionally allows the route module to be absent while tests stay assertion-driven.
		if (isMissingPricingRouteModule(error)) {
			return;
		}
		throw error;
	}

	if (
		!module ||
		typeof module !== 'object' ||
		!('default' in module) ||
		typeof module.default !== 'function'
	) {
		throw new Error('Expected /pricing route module to export a default Svelte component.');
	}

	render(module.default as Component<PricingPageProps>, { data: { pricing } });
}

describe('Pricing page', () => {
	it('only treats true missing-module import errors as tolerated Stage 2 route gaps', () => {
		const missingModuleError = new Error(
			"Cannot find module './+page.svelte' imported from pricing.test.ts"
		);
		const missingModuleAbsolutePathError = new Error(
			"Cannot find module '/repo/web/src/routes/pricing/+page.svelte' imported from pricing.test.ts"
		);
		const missingViteUrlError = new Error(
			'Failed to load url ./+page.svelte (resolved id: ./+page.svelte). Does the file exist?'
		);
		const dependencyMissingFromRouteError = new Error(
			"Cannot find module '$lib/pricing-view-model' imported from /repo/web/src/routes/pricing/+page.svelte"
		);
		const dependencyMissingViteUrlError = new Error(
			'Failed to load url /src/lib/pricing-view-model.ts (resolved id: /src/lib/pricing-view-model.ts). Does the file exist?'
		);
		const runtimeImportError = new Error(
			'Failed to load url ./+page.svelte due to SyntaxError: Unexpected token'
		);

		expect(isMissingPricingRouteModule(missingModuleError)).toBe(true);
		expect(isMissingPricingRouteModule(missingModuleAbsolutePathError)).toBe(true);
		expect(isMissingPricingRouteModule(missingViteUrlError)).toBe(true);
		expect(isMissingPricingRouteModule(dependencyMissingFromRouteError)).toBe(false);
		expect(isMissingPricingRouteModule(dependencyMissingViteUrlError)).toBe(false);
		expect(isMissingPricingRouteModule(runtimeImportError)).toBe(false);
	});

	it('renders through the shared layout trust owner while preserving pricing-specific route content', () => {
		pageState.url = new URL('http://localhost/pricing');
		render(PricingLayoutTestWrapper);

		expect(screen.getByTestId('public-beta-banner')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /learn about the beta/i })).toHaveAttribute(
			'href',
			'/beta'
		);
		expect(screen.getByRole('heading', { level: 1, name: /pricing/i })).toBeInTheDocument();
		expect(screen.getByTestId('pricing-page-main')).toBeInTheDocument();
		expect(screen.getByRole('contentinfo')).toBeInTheDocument();
	});

	it('renders pricing-specific heading/body copy, free-tier allowance, and signup CTA sourced from shared pricing data', async () => {
		await renderPricingPage();

		expect(screen.getByRole('heading', { level: 1, name: /pricing/i })).toBeInTheDocument();
		expect(
			screen.getByText(
				'Use straightforward monthly pricing in USD without managing infrastructure billing logic.'
			)
		).toBeInTheDocument();
		expect(screen.getByText(MARKETING_PRICING.free_tier_promise)).toBeInTheDocument();
		expect(
			screen.getByText(
				`Free up to ${MARKETING_PRICING.free_tier_indexes} indices, ${US_INTEGER_FORMATTER.format(MARKETING_PRICING.free_tier_records)} records, ${MARKETING_PRICING.free_tier_mb} MB storage, and ${US_INTEGER_FORMATTER.format(MARKETING_PRICING.free_tier_searches_per_month)} searches/month. No credit card required.`
			)
		).toBeInTheDocument();
		expect(
			screen.getByText(
				`Every account includes ${MARKETING_PRICING.free_tier_mb} MB of hot index storage before paid billing starts.`
			)
		).toBeInTheDocument();
		expect(screen.getByText(MARKETING_PRICING.storage_rate_per_mb_month)).toBeInTheDocument();
		expect(
			screen.getByText(MARKETING_PRICING.cold_storage_rate_per_gb_month)
		).toBeInTheDocument();
		expect(screen.getByText(formatCents(MARKETING_PRICING.shared_minimum_spend_cents))).toBeInTheDocument();
		expect(
			screen.getByText(expectedFreeTierUpgradeCopy(MARKETING_PRICING.shared_minimum_spend_cents))
		).toBeInTheDocument();
		expect(screen.getByText(`${MARKETING_PRICING.free_tier_max_indexes} indices`)).toBeInTheDocument();
		expect(
			screen.getByText(`${US_INTEGER_FORMATTER.format(MARKETING_PRICING.free_tier_max_records)} records`)
		).toBeInTheDocument();
		expect(screen.getByText(`${MARKETING_PRICING.free_tier_mb} MB hot storage`)).toBeInTheDocument();
		expect(
			screen.getByText(
				`${US_INTEGER_FORMATTER.format(MARKETING_PRICING.free_tier_max_searches_per_month)} searches per month`
			)
		).toBeInTheDocument();

		// URL-obscurity beta gate: pricing CTA removed.
		// See docs/decisions/2026_05_23_beta_signup_gate.md.
		const pricingMain = screen.getByTestId('pricing-page-main');
		expect(
			within(pricingMain).queryByRole('link', { name: MARKETING_PRICING.cta_label })
		).not.toBeInTheDocument();
	});

	it('renders mutated CTA, free-tier MB, minimum spend, and region ordering from route payload data', async () => {
		const reversedRegions = [...MARKETING_PRICING.region_pricing].reverse();
		const mutatedPricing = {
			...MARKETING_PRICING,
			cta_label: 'Launch Free Workspace',
			free_tier_mb: 987,
			free_tier_max_indexes: 11,
			free_tier_max_records: 654_321,
			free_tier_max_searches_per_month: 76_543,
			minimum_spend_cents: 0,
			shared_minimum_spend_cents: 43210,
			region_pricing: reversedRegions
		};

		await renderPricingPage(mutatedPricing);
		const pricingMain = screen.getByTestId('pricing-page-main');

		expect(
			screen.getByText(
				`Every account includes ${mutatedPricing.free_tier_mb} MB of hot index storage before paid billing starts.`
			)
		).toBeInTheDocument();
		// URL-obscurity beta gate: pricing CTA removed.
		// See docs/decisions/2026_05_23_beta_signup_gate.md.
		expect(
			within(pricingMain).queryByRole('link', { name: mutatedPricing.cta_label })
		).not.toBeInTheDocument();
		expect(
			within(pricingMain).getByText(formatCents(mutatedPricing.shared_minimum_spend_cents))
		).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(
				expectedFreeTierUpgradeCopy(mutatedPricing.shared_minimum_spend_cents)
			)
		).toBeInTheDocument();
		expect(within(pricingMain).getByText(`${mutatedPricing.free_tier_mb} MB hot storage`)).toBeInTheDocument();
		expect(within(pricingMain).getByText(`${mutatedPricing.free_tier_max_indexes} indices`)).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(
				`${US_INTEGER_FORMATTER.format(mutatedPricing.free_tier_max_records)} records`
			)
		).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(
				`${US_INTEGER_FORMATTER.format(mutatedPricing.free_tier_max_searches_per_month)} searches per month`
			)
		).toBeInTheDocument();

		const regionTable = within(pricingMain).getByRole('table', { name: 'Region multipliers' });
		const regionRows = within(regionTable).getAllByRole('row').slice(1);
		const renderedRegionPairs = regionRows.map((row) => {
			const renderedRegion = within(row).getByRole('rowheader').textContent?.trim() ?? '';
			const renderedMultiplier = within(row).getByRole('cell').textContent?.trim() ?? '';
			return [renderedRegion, renderedMultiplier];
		});
		const expectedRegionPairs = reversedRegions.map((region) => [
			region.display_name,
			region.multiplier
		]);
		expect(renderedRegionPairs).toEqual(expectedRegionPairs);
	});

	it('renders hot/cold storage rows, minimum spend, and ordered region multipliers from MARKETING_PRICING', async () => {
		const pricingWithLargeMinimumSpend = {
			...MARKETING_PRICING,
			minimum_spend_cents: 0,
			shared_minimum_spend_cents: 123456
		};
		await renderPricingPage(pricingWithLargeMinimumSpend);
		const pricingMain = screen.getByTestId('pricing-page-main');

		expect(within(pricingMain).getByText('Hot index storage')).toBeInTheDocument();
		expect(within(pricingMain).getByText('Cold snapshot storage')).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(MARKETING_PRICING.storage_rate_per_mb_month)
		).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(MARKETING_PRICING.cold_storage_rate_per_gb_month)
		).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(formatCents(pricingWithLargeMinimumSpend.shared_minimum_spend_cents))
		).toBeInTheDocument();
		// Regression: upgrade-copy sentence must preserve thousands separators via the shared helper.
		expect(
			within(pricingMain).getByText(
				expectedFreeTierUpgradeCopy(pricingWithLargeMinimumSpend.shared_minimum_spend_cents)
			)
		).toBeInTheDocument();
		expect(
			within(pricingMain).getByText(
				expectedFreeTierUpgradeCopy(pricingWithLargeMinimumSpend.shared_minimum_spend_cents)
			)
		).toHaveTextContent('$1,234.56');

		const regionTable = within(pricingMain).getByRole('table', { name: 'Region multipliers' });
		const regionRows = within(regionTable).getAllByRole('row').slice(1);
		expect(regionRows).toHaveLength(MARKETING_PRICING.region_pricing.length);

		const renderedRegionPairs = regionRows.map((row) => {
			const renderedRegion = within(row).getByRole('rowheader').textContent?.trim() ?? '';
			const renderedMultiplier = within(row).getByRole('cell').textContent?.trim() ?? '';
			return [renderedRegion, renderedMultiplier];
		});
		const expectedRegionPairs = EXPECTED_REGIONS.map((region, index) => [
			region,
			MARKETING_PRICING.region_pricing[index].multiplier
		]);
		expect(renderedRegionPairs).toEqual(expectedRegionPairs);
	});

	it('keeps landing-only framing out of /pricing page body', async () => {
		await renderPricingPage();
		const pricingMain = screen.getByTestId('pricing-page-main');

		expect(pricingMain).toBeInTheDocument();
		expect(pricingMain).not.toHaveTextContent('What you get');
		expect(pricingMain).not.toHaveTextContent('Quick facts');
		expect(pricingMain).not.toHaveTextContent(/Page not found|Not found/i);
		expect(within(pricingMain).queryByText('Support reference')).not.toBeInTheDocument();
		expect(screen.queryByTestId('landing-pricing-calculator')).not.toBeInTheDocument();
	});
});
