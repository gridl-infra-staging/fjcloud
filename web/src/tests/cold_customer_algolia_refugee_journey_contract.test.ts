import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const requiredContractSource = readFileSync(
	join(process.cwd(), 'tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts'),
	'utf8'
);

describe('cold-customer required staging contract', () => {
	it('fails closed instead of skipping when prerequisites are unavailable', () => {
		expect(requiredContractSource).not.toMatch(/\btest\.skip\s*\(/);
		expect(requiredContractSource).toMatch(/E2E_ADMIN_KEY required/);
		expect(requiredContractSource).toMatch(/signup prerequisite unavailable/);
	});

	it('scopes verification replay error copy to the verify-result card', () => {
		expect(requiredContractSource).not.toContain(
			"page.getByText('invalid or expired verification token')"
		);
		expect(requiredContractSource).toMatch(
			/page\.getByTestId\('verify-result'\)[\s\S]*getByText\('invalid or expired verification token'/
		);
	});
});
