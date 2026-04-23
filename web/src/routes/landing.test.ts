import { describe, it, expect, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';

import LandingPage from './+page.svelte';
import { MARKETING_PRICING } from '$lib/pricing';

afterEach(cleanup);

describe('Landing page', () => {
	const pricingData = MARKETING_PRICING;

	it('renders direct hero copy and CTA', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		expect(screen.getByRole('heading', { level: 1, name: 'Flapjack Cloud' })).toBeInTheDocument();
		expect(screen.getByText('Managed hosting for Flapjack search.')).toBeInTheDocument();
		expect(screen.getByText(/Use an Algolia-compatible API/)).toBeInTheDocument();
		const ctaLinks = screen.getAllByRole('link', { name: MARKETING_PRICING.cta_label });
		expect(ctaLinks.length).toBeGreaterThanOrEqual(1);
		expect(ctaLinks[0]).toHaveAttribute('href', '/signup');
	});

	it('renders public beta framing and policy links before signup', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		expect(screen.getAllByText(/public beta/i).length).toBeGreaterThanOrEqual(1);
		expect(screen.getByRole('link', { name: /learn about the beta/i })).toHaveAttribute(
			'href',
			'/beta'
		);
		expect(screen.getAllByRole('link', { name: 'Terms' })[0]).toHaveAttribute('href', '/terms');
		expect(screen.getAllByRole('link', { name: 'Privacy' })[0]).toHaveAttribute('href', '/privacy');
		expect(screen.getAllByRole('link', { name: 'DPA' })[0]).toHaveAttribute('href', '/dpa');
	});

	it('links to the open-source Flapjack repository from the header', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		const githubLink = screen.getByRole('link', { name: 'GitHub repository' });
		expect(githubLink).toHaveAttribute('href', 'https://github.com/gridlhq/flapjack');
	});

	it('publishes canonical link preview metadata for the cloud site', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		expect(document.head.querySelector('link[rel="canonical"]')).toHaveAttribute(
			'href',
			'https://cloud.flapjack.foo/'
		);
		expect(document.head.querySelector('meta[property="og:title"]')).toHaveAttribute(
			'content',
			'Flapjack Cloud'
		);
		expect(document.head.querySelector('meta[property="og:image"]')).toHaveAttribute(
			'content',
			'https://cloud.flapjack.foo/flapjack_cloud_preview.png'
		);
		expect(document.head.querySelector('meta[name="twitter:card"]')).toHaveAttribute(
			'content',
			'summary_large_image'
		);
	});

	it('renders pricing table with per-MB storage and no legacy search/write rows', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		expect(screen.getByText('$0.05')).toBeInTheDocument();
		expect(screen.getByText('$0.02')).toBeInTheDocument();
		expect(screen.getByText(/per MB-month/)).toBeInTheDocument();
		// Legacy rows removed
		expect(screen.queryByText('Search Requests')).not.toBeInTheDocument();
		expect(screen.queryByText('Write Operations')).not.toBeInTheDocument();
		expect(screen.queryByText(/compute/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/vm-hour/i)).not.toBeInTheDocument();
	});

	it('CTA links to signup', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		const ctaLinks = screen.getAllByRole('link', { name: MARKETING_PRICING.cta_label });
		ctaLinks.forEach((link) => {
			expect(link).toHaveAttribute('href', '/signup');
		});
	});

	it('page loads without auth — no login form or dashboard elements', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		expect(screen.queryByLabelText('Email')).not.toBeInTheDocument();
		expect(screen.queryByLabelText('Password')).not.toBeInTheDocument();
		expect(screen.queryByText('Logout')).not.toBeInTheDocument();
	});

	it('pricing_calculator_shows_cold_rate', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		// Cold storage rate should be displayed in the pricing table
		expect(screen.getByText('$0.02')).toBeInTheDocument();
		expect(screen.getByText(/cold snapshot storage/i)).toBeInTheDocument();
	});

	it('pricing_calculator_shows_single_minimum_spend', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		expect(screen.queryByTestId('pricing-mode-shared')).not.toBeInTheDocument();
		expect(screen.queryByTestId('pricing-mode-dedicated')).not.toBeInTheDocument();
		expect(screen.getByTestId('minimum-spend')).toHaveTextContent('$10.00');
	});

	it('pricing_calculator_shows_regions_without_provider_details', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		expect(screen.getByText('EU Central (Germany)')).toBeInTheDocument();
		expect(screen.getByText('EU North (Helsinki)')).toBeInTheDocument();
		expect(screen.getByText('US East (Ashburn)')).toBeInTheDocument();
		expect(screen.getByText('US West (Oregon)')).toBeInTheDocument();

		expect(screen.queryByText('AWS')).not.toBeInTheDocument();
		expect(screen.queryByText('Hetzner')).not.toBeInTheDocument();
		expect(screen.queryByText(/provider/i)).not.toBeInTheDocument();
		expect(screen.queryByTestId('provider-filter-all')).not.toBeInTheDocument();
		expect(screen.queryByTestId('provider-filter-aws')).not.toBeInTheDocument();
		expect(screen.queryByTestId('provider-filter-hetzner')).not.toBeInTheDocument();

		expect(screen.getByText('0.70x')).toBeInTheDocument();
		expect(screen.getByText('0.75x')).toBeInTheDocument();
		expect(screen.getAllByText('0.80x')).toHaveLength(2);
	});

	it('uses direct copy with no infrastructure-language marketing', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		expect(screen.getByText(/Search and write requests are quota-limited/i)).toBeInTheDocument();
		expect(screen.getAllByText(MARKETING_PRICING.free_tier_promise).length).toBeGreaterThanOrEqual(
			1
		);
		expect(screen.queryByText(/that just works/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/deploy/i)).not.toBeInTheDocument();
	});

	it('highlights concrete Flapjack search capabilities', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		expect(
			screen.getByRole('heading', { level: 3, name: 'Algolia-compatible API' })
		).toBeInTheDocument();
		expect(
			screen.getByRole('heading', { level: 3, name: 'InstantSearch works' })
		).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 3, name: 'Search features' })).toBeInTheDocument();
		expect(screen.getByText(/Typo tolerance, filters, faceting, geo search/i)).toBeInTheDocument();
		expect(
			screen.getByRole('heading', { level: 3, name: 'Algolia migration' })
		).toBeInTheDocument();
		expect(screen.queryByRole('heading', { level: 3, name: 'Support' })).not.toBeInTheDocument();
	});
	it('renders shared free-tier promise in hero, pricing, and CTA sections', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		const heroSection = screen
			.getByRole('heading', { level: 1, name: 'Flapjack Cloud' })
			.closest('section');
		const pricingSection = screen
			.getByRole('heading', { level: 2, name: 'Simple pricing' })
			.closest('section');
		const ctaSection = screen
			.getByRole('heading', { level: 2, name: 'Start with a free beta account' })
			.closest('section');

		expect(heroSection).not.toBeNull();
		expect(pricingSection).not.toBeNull();
		expect(ctaSection).not.toBeNull();

		expect(within(heroSection!).getByText(MARKETING_PRICING.free_tier_promise)).toBeInTheDocument();
		expect(
			within(pricingSection!).getByText(MARKETING_PRICING.free_tier_promise)
		).toBeInTheDocument();
		expect(within(ctaSection!).getByText(MARKETING_PRICING.free_tier_promise)).toBeInTheDocument();
	});
	it('how it works does not mention adding a payment method', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		expect(screen.queryByText(/add a payment method/i)).not.toBeInTheDocument();
	});

	it('landing page mentions no credit card required', () => {
		render(LandingPage, { data: { pricing: pricingData } });
		const matches = screen.getAllByText(/no credit card required/i);
		expect(matches.length).toBeGreaterThanOrEqual(1);
	});

	it('renders Stripe-review policy content', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		expect(screen.getByText(/Prices are in USD/i)).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 3, name: 'Delivery' })).toBeInTheDocument();
		expect(screen.getByText(/Nothing is shipped/i)).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 3, name: 'Cancellation' })).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 3, name: 'Refunds' })).toBeInTheDocument();
		expect(
			screen.getByText(/duplicate charges, billing errors, or service unavailability/i)
		).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 3, name: 'Payment security' })).toBeInTheDocument();
		expect(screen.getByText(/Flapjack Cloud does not store card numbers/i)).toBeInTheDocument();
		expect(screen.getAllByText(/support@flapjack.foo/i).length).toBeGreaterThanOrEqual(1);
	});

	it('renders the landing pricing calculator section', () => {
		render(LandingPage, { data: { pricing: pricingData } });

		expect(screen.getByTestId('landing-pricing-calculator')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Compare monthly cost' })).toBeInTheDocument();
	});

	it('keeps CTA, pricing rates, free-tier promise, and region copy sourced from data.pricing', () => {
		const customPricing = {
			...MARKETING_PRICING,
			storage_rate_per_mb_month: '$7.77',
			cold_storage_rate_per_gb_month: '$6.66',
			cta_label: 'Start Free Now',
			free_tier_promise: 'Custom free tier promise for test.',
			region_pricing: [{ id: 'moon-1', display_name: 'Moon Test Region', multiplier: '1.23x' }]
		};

		render(LandingPage, { data: { pricing: customPricing } });

		expect(screen.getByText(customPricing.storage_rate_per_mb_month)).toBeInTheDocument();
		expect(screen.getByText(customPricing.cold_storage_rate_per_gb_month)).toBeInTheDocument();
		expect(screen.getAllByText(customPricing.free_tier_promise).length).toBeGreaterThanOrEqual(1);

		const ctaLinks = screen.getAllByRole('link', { name: customPricing.cta_label });
		expect(ctaLinks.length).toBeGreaterThanOrEqual(1);

		expect(screen.getByText('Moon Test Region')).toBeInTheDocument();
		expect(screen.getByText('1.23x')).toBeInTheDocument();
	});
});
