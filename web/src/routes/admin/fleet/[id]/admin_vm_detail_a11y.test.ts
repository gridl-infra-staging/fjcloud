import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { getAccessibilityViolations } from '../../../../tests/a11y';
import {
	EMPTY_LIFECYCLE_RESPONSE,
	LIFECYCLE_EVENTS_FIXTURE,
	vmDetailPageData
} from '../admin_fleet_fixtures';
import VmDetailPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn()
}));

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Admin VM detail page accessibility', () => {
	it('has no structural accessibility violations for populated and empty lifecycle states', async () => {
		const { container } = render(VmDetailPage, {
			data: vmDetailPageData(LIFECYCLE_EVENTS_FIXTURE)
		});
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		cleanup();
		const { container: emptyContainer } = render(VmDetailPage, {
			data: vmDetailPageData(EMPTY_LIFECYCLE_RESPONSE)
		});
		await expect(getAccessibilityViolations(emptyContainer)).resolves.toEqual([]);
	});
});
