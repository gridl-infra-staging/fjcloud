import { stringify } from 'devalue';
import { expect, test } from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

type ConversionPayload = {
	country: string | null;
	countries: string[];
	trend: Array<{ date: string; conversionRate: number }>;
	kpis: {
		ctr: { current: number; previous: number; delta: number };
		addToCart: { current: number; previous: number; delta: number };
		purchase: { current: number; previous: number; delta: number };
		conversionRate: { current: number; previous: number; delta: number };
	};
};

test.describe('Analytics conversions subtab', () => {
	test.describe.configure({ timeout: 90_000 });

	test('renders conversion KPI cards, trend chart, and country-scoped reload from server payload', async ({
		page,
		arrangeTrackedCustomerSession,
		seedCustomerIndex,
		testRegion
	}) => {
		const customer = await arrangeTrackedCustomerSession(page, {
			emailPrefix: 'e2e-analytics-conversions'
		});
		const indexName = `e2e-analytics-conversions-${Date.now()}`;
		await seedCustomerIndex(customer, indexName, testRegion);

		const conversionRequests: Array<{ country: string | null }> = [];
		const firstPayload: ConversionPayload = {
			country: null,
			countries: ['US', 'CA'],
			trend: [
				{ date: '2026-02-18', conversionRate: 0.025 },
				{ date: '2026-02-19', conversionRate: 0.027 }
			],
			kpis: {
				ctr: { current: 0.123, previous: 0.11, delta: 0.013 },
				addToCart: { current: 0.345, previous: 0.31, delta: 0.035 },
				purchase: { current: 0.067, previous: 0.06, delta: 0.007 },
				conversionRate: { current: 0.025, previous: 0.02, delta: 0.005 }
			}
		};
		const secondPayload: ConversionPayload = {
			country: 'US',
			countries: ['US', 'CA'],
			trend: [
				{ date: '2026-02-18', conversionRate: 0.031 },
				{ date: '2026-02-19', conversionRate: 0.033 }
			],
			kpis: {
				ctr: { current: 0.2, previous: 0.18, delta: 0.02 },
				addToCart: { current: 0.4, previous: 0.35, delta: 0.05 },
				purchase: { current: 0.08, previous: 0.07, delta: 0.01 },
				conversionRate: { current: 0.033, previous: 0.028, delta: 0.005 }
			}
		};

		await page.route('**/console/indexes/**', async (route, request) => {
			if (request.method() === 'POST' && request.url().includes('fetchAnalyticsConversionRate')) {
				const postData = request.postData() ?? '';
				const body = new URLSearchParams(postData);
				const country = body.get('country');
				conversionRequests.push({
					country: country && country.trim().length > 0 ? country : null
				});
				const payload = country && country.trim().length > 0 ? secondPayload : firstPayload;
				await route.fulfill({
					status: 200,
					contentType: 'application/json',
					body: JSON.stringify({
						type: 'success',
						status: 200,
						data: stringify({ analyticsConversionRate: payload })
					})
				});
				return;
			}

			await route.continue();
		});

		await page.goto(
			`/console/indexes/${encodeURIComponent(indexName)}?tab=analytics&subtab=conversions`
		);

		await expect(page.getByTestId('tab-analytics')).toHaveAttribute('aria-selected', 'true');
		await expect(page.getByTestId('analytics-subtab-conversions')).toHaveAttribute(
			'aria-selected',
			'true'
		);
		await expect(page.getByTestId('conversion-kpi-ctr')).toContainText('12.3%');
		await expect(page.getByTestId('conversion-kpi-addToCart')).toContainText('34.5%');
		await expect(page.getByTestId('conversion-kpi-purchase')).toContainText('6.7%');
		await expect(page.getByTestId('conversion-kpi-conversionRate')).toContainText('2.5%');
		await expect(page.getByTestId('conversion-kpi-ctr-delta')).toBeVisible();
		await expect(page.getByTestId('conversion-kpi-addToCart-delta')).toBeVisible();
		await expect(page.getByTestId('conversion-kpi-purchase-delta')).toBeVisible();
		await expect(page.getByTestId('conversion-kpi-conversionRate-delta')).toBeVisible();
		await expect(page.getByTestId('conversion-trend-chart')).toBeVisible();

		const requestCountBeforeCountryChange = conversionRequests.length;
		await page.getByTestId('conversion-country-filter').selectOption('US');

		await expect
			.poll(() => conversionRequests.length, {
				message: 'expected an additional conversions POST after country change'
			})
			.toBeGreaterThan(requestCountBeforeCountryChange);
		const countryScopedRequest = conversionRequests
			.slice(requestCountBeforeCountryChange)
			.find((entry) => entry.country === 'US');
		expect(countryScopedRequest).toBeTruthy();

		await expect(page.getByTestId('conversion-kpi-ctr')).toContainText('20.0%');
		await expect(page.getByTestId('conversion-kpi-addToCart')).toContainText('40.0%');
		await expect(page.getByTestId('conversion-kpi-purchase')).toContainText('8.0%');
		await expect(page.getByTestId('conversion-kpi-conversionRate')).toContainText('3.3%');
	});
});
