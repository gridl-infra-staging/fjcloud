import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { getAccessibilityViolations } from '../../../../tests/a11y';
import { ACTIVE_DETAIL_FIXTURE, DETAIL_FIXTURE } from '../admin-customer-detail.test-fixtures';
import CustomerDetailPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	applyAction: vi.fn(),
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn()
}));

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Admin customer detail accessibility', () => {
	it('has no structural accessibility violations for populated, tabbed, success, and error states', async () => {
		const { container } = render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE }
		});
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		await fireEvent.click(screen.getByRole('button', { name: 'Indexes' }));
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		cleanup();
		const { container: successContainer } = render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...ACTIVE_DETAIL_FIXTURE },
			form: { message: 'Customer updated' }
		});
		await expect(getAccessibilityViolations(successContainer)).resolves.toEqual([]);

		cleanup();
		const { container: errorContainer } = render(CustomerDetailPage, {
			data: { environment: 'test', isAuthenticated: true, ...DETAIL_FIXTURE },
			form: { error: 'Update failed' }
		});
		await expect(getAccessibilityViolations(errorContainer)).resolves.toEqual([]);
	});
});
