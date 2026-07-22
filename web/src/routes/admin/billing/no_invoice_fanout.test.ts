import { describe, expect, it } from 'vitest';
import pageServerSource from './+page.server.ts?raw';

describe('Admin billing loader SSOT guard', () => {
	it('uses the billing summary endpoint instead of tenant invoice fan-out', () => {
		expect(pageServerSource).toContain('getBillingSummary(');
		expect(pageServerSource).not.toContain('getTenantInvoices');
		expect(pageServerSource).not.toContain('Promise.all(');
		expect(pageServerSource).not.toContain('tenants.map(');
	});
});
