import { describe, expect, it } from 'vitest';
import pageServerSource from './+page.server.ts?raw';

describe('Admin customers loader SSOT guard', () => {
	// Stage 4 contract owner: list loader must not perform per-tenant invoice fan-out.
	it('does not reintroduce per-tenant invoice fan-out helpers', () => {
		// This is a regression guard against reintroducing N+1 invoice fan-out
		// into the list loader after billing health became part of GET /admin/tenants.
		expect(pageServerSource).not.toContain('loadLastInvoiceStatus');
		expect(pageServerSource).not.toContain('latestInvoiceStatus');
		expect(pageServerSource).not.toContain('getTenantInvoices');
		expect(pageServerSource).not.toContain('last_invoice_status');
		expect(pageServerSource).not.toContain('Promise.all(');
		expect(pageServerSource).not.toMatch(/tenants\.map\(\s*async/m);
		expect(pageServerSource).toContain('client.getTenants()');
		expect(pageServerSource).toContain('tenants.map(toCustomerListItem)');
	});
});
