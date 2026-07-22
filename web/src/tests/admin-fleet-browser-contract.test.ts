import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const fleetBrowserSpec = readFileSync(
	join(process.cwd(), 'tests/e2e-ui/full/admin/fleet.spec.ts'),
	'utf8'
);

describe('admin fleet browser contract', () => {
	it('uses human-reachable locators instead of raw CSS selectors', () => {
		expect(fleetBrowserSpec).not.toMatch(/\.locator\(/);
	});
});
