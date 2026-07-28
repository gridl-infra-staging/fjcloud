import { test, expect } from '../../fixtures/fixtures';

test.use({ storageState: { cookies: [], origins: [] } });

const PRIVATE_KEYS = [
	'vms',
	'machines',
	'hostname',
	'flapjack_url',
	'capacity',
	'current_load',
	'vm_id',
	'healthy_count',
	'unhealthy_count',
	'unknown_count'
] as const;

function collectKeys(value: unknown): string[] {
	if (Array.isArray(value)) {
		return value.flatMap(collectKeys);
	}
	if (value === null || typeof value !== 'object') {
		return [];
	}

	return Object.entries(value).flatMap(([key, nestedValue]) => [key, ...collectKeys(nestedValue)]);
}

test.describe('Public infrastructure', () => {
	test('renders current region-level infrastructure for an anonymous visitor', async ({
		page,
		arrangePublicInfrastructureCanaryVm
	}) => {
		const privacyCanary = await arrangePublicInfrastructureCanaryVm();

		await page.goto('/infrastructure');

		const main = page.getByTestId('public-infrastructure-main');
		await expect(page.getByRole('heading', { name: 'Infrastructure', level: 1 })).toBeVisible();
		await expect(page.getByTestId('infrastructure-availability')).toContainText(
			/Availability (?:unavailable|[\d,.]+%)/
		);

		const regionRows = page.getByTestId(/^infrastructure-region-row-/);
		expect(await regionRows.count()).toBeGreaterThan(0);
		await expect(regionRows.first()).toBeVisible();
		await expect(regionRows.first().getByRole('cell').first()).toContainText(/\S+/);
		await expect(page.getByTestId(/^infrastructure-health-/).first()).toContainText(
			/Operational|Degraded|Outage|Unknown/
		);
		await expect(page.getByTestId(/^infrastructure-utilization-/).first()).toContainText(
			/Green|Yellow|Red|—/
		);

		const kAnonymityRegionRow = page.getByTestId(
			`infrastructure-region-row-${privacyCanary.kAnonymityRegion}`
		);
		await expect(
			page.getByTestId(`infrastructure-utilization-${privacyCanary.kAnonymityRegion}`)
		).toHaveText('—');
		await expect(kAnonymityRegionRow.getByRole('cell').last()).toHaveText('1');

		const fullHtml = await page.content();
		for (const sentinel of privacyCanary.forbiddenText) {
			await expect(main).not.toContainText(sentinel);
			expect(fullHtml).not.toContain(sentinel);
		}
	});

	test('raw public JSON is anonymous and contains only the public region contract', async ({
		arrangePublicInfrastructureCanaryVm,
		getPublicInfrastructureRaw
	}) => {
		const privacyCanary = await arrangePublicInfrastructureCanaryVm();
		const { status, body, text } = await getPublicInfrastructureRaw();

		expect(status).toBe(200);
		expect(body).not.toBeNull();
		expect(Array.isArray(body)).toBe(false);

		const payload = body as Record<string, unknown>;
		expect(Object.keys(payload).sort()).toEqual(['overall', 'regions']);

		const overall = payload.overall as Record<string, unknown>;
		expect(Object.keys(overall).sort()).toEqual(['availability_pct', 'total_regions', 'total_vms']);

		expect(Array.isArray(payload.regions)).toBe(true);
		const regions = payload.regions as Array<Record<string, unknown>>;
		expect(regions.length).toBeGreaterThan(0);
		for (const region of regions) {
			expect(Object.keys(region).sort()).toEqual([
				'display_name',
				'health',
				'provider',
				'provider_location',
				'region',
				'utilization',
				'vm_count'
			]);
		}

		const allKeys = collectKeys(body);
		for (const privateKey of PRIVATE_KEYS) {
			expect(allKeys).not.toContain(privateKey);
		}
		for (const sentinel of privacyCanary.forbiddenText) {
			expect(text).not.toContain(sentinel);
		}
	});
});
