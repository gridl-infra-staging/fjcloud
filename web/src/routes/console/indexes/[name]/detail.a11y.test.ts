import { afterEach, describe, expect, it } from 'vitest';
import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { resetDetailPageTestState } from './detail_test_harness';
import IndexDetailPage from './+page.svelte';
import { createMockPageData } from './detail.test.shared';
import { getAccessibilityViolations } from '../../../../tests/a11y';

afterEach(resetDetailPageTestState);

describe('Index detail page accessibility', () => {
	it('has no structural accessibility violations for overview and populated analytics states', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		await fireEvent.click(screen.getByRole('tab', { name: 'Analytics' }));
		const analyticsPanel = screen.getByTestId('analytics-section');
		expect(within(analyticsPanel).getByText('1,234')).toBeInTheDocument();
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});
});
