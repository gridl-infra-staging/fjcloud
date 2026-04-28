import { describe, expect, it } from 'vitest';
import { auditActionLabel } from './audit';

describe('auditActionLabel', () => {
	it.each([
		['impersonation_token_created', 'Impersonation token created'],
		['tenant_created', 'Customer created'],
		['tenant_updated', 'Customer updated'],
		['tenant_deleted', 'Customer deleted'],
		['customer_suspended', 'Customer suspended'],
		['customer_reactivated', 'Customer reactivated'],
		['stripe_sync', 'Stripe sync triggered'],
		['rate_card_override', 'Rate card override updated'],
		['quotas_updated', 'Quotas updated']
	])('maps %s to a deterministic operator-facing label', (action, expectedLabel) => {
		expect(auditActionLabel(action)).toBe(expectedLabel);
	});

	it('falls back safely for unknown future action names', () => {
		expect(auditActionLabel('new_future_action')).toBe('New Future Action');
		expect(auditActionLabel('')).toBe('Unknown action');
	});
});
