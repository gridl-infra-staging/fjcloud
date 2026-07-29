import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { getAccessibilityViolations } from '../../../tests/a11y';
import { FLEET_FIXTURES, VM_FIXTURES, fleetPageData } from './admin_fleet_fixtures';
import FleetPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: () => Promise.resolve()
}));

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Admin fleet page accessibility', () => {
	it('has no structural accessibility violations for the populated state', async () => {
		const { container } = render(FleetPage, {
			data: fleetPageData({ fleet: FLEET_FIXTURES, vms: VM_FIXTURES }),
			form: null
		});

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it('has no structural accessibility violations for the filtered state', async () => {
		const { container } = render(FleetPage, {
			data: fleetPageData({ fleet: FLEET_FIXTURES, vms: VM_FIXTURES }),
			form: null
		});
		await fireEvent.change(document.querySelector('[data-testid="provider-filter"]')!, {
			target: { value: 'aws' }
		});

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it('has no structural accessibility violations for unavailable states', async () => {
		const { container: unavailableContainer } = render(FleetPage, {
			data: fleetPageData({ fleetAvailable: false, vmCapacityAvailable: false }),
			form: null
		});

		await expect(getAccessibilityViolations(unavailableContainer)).resolves.toEqual([]);
	});
});
