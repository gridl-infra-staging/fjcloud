import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import type { Component } from 'svelte';
import { formatCents } from '$lib/format';
import { MARKETING_PRICING } from '$lib/pricing';

afterEach(cleanup);

const EXPECTED_REGIONS = MARKETING_PRICING.region_pricing.map((region) => region.display_name);
const PRICING_ROUTE_COMPONENT_PATH = './+page.svelte';
const PRICING_ROUTE_MODULE_IDENTIFIERS = ['./+page.svelte', '/routes/pricing/+page.svelte'];
type PricingPageProps = { data: { pricing: typeof MARKETING_PRICING } };

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

	it('renders pricing-specific heading/body copy, free-tier allowance, and signup CTA sourced from shared pricing data', async () => {
		await renderPricingPage();

		expect(screen.getByRole('heading', { level: 1, name: /pricing/i })).toBeInTheDocument();
		expect(screen.getByText(MARKETING_PRICING.free_tier_promise)).toBeInTheDocument();
		expect(
			screen.getByText(new RegExp(`${MARKETING_PRICING.free_tier_mb}\\s+MB`))
		).toBeInTheDocument();

		const pricingMain = screen.getByTestId('pricing-page-main');
		const cta = within(pricingMain).getByRole('link', { name: MARKETING_PRICING.cta_label });
		expect(cta).toHaveAttribute('href', '/signup');
	});

	it('renders mutated CTA, free-tier MB, minimum spend, and region ordering from route payload data', async () => {
		const reversedRegions = [...MARKETING_PRICING.region_pricing].reverse();
		const mutatedPricing = {
			...MARKETING_PRICING,
			cta_label: 'Launch Free Workspace',
			free_tier_mb: 987,
			minimum_spend_cents: 43210,
			region_pricing: reversedRegions
		};

		await renderPricingPage(mutatedPricing);
		const pricingMain = screen.getByTestId('pricing-page-main');

		expect(screen.getByText(new RegExp(`${mutatedPricing.free_tier_mb}\\s+MB`))).toBeInTheDocument();
		expect(within(pricingMain).getByRole('link', { name: mutatedPricing.cta_label })).toHaveAttribute(
			'href',
			'/signup'
		);
		expect(within(pricingMain).getByText(formatCents(mutatedPricing.minimum_spend_cents))).toBeInTheDocument();

		const regionTable = within(pricingMain).getByRole('table', { name: 'Region multipliers' });
		const regionRows = within(regionTable).getAllByRole('row').slice(1);
		const renderedRegionPairs = regionRows.map((row) => {
			const renderedRegion = within(row).getByRole('rowheader').textContent?.trim() ?? '';
			const renderedMultiplier = within(row).getByRole('cell').textContent?.trim() ?? '';
			return [renderedRegion, renderedMultiplier];
		});
		const expectedRegionPairs = reversedRegions.map((region) => [region.display_name, region.multiplier]);
		expect(renderedRegionPairs).toEqual(expectedRegionPairs);
	});

	it('renders hot/cold storage rows, minimum spend, and ordered region multipliers from MARKETING_PRICING', async () => {
		const pricingWithLargeMinimumSpend = {
			...MARKETING_PRICING,
			minimum_spend_cents: 123456
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
			within(pricingMain).getByText(formatCents(pricingWithLargeMinimumSpend.minimum_spend_cents))
		).toBeInTheDocument();

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
