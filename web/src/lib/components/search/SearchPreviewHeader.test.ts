import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewHeader from './SearchPreviewHeader.svelte';
import TrackAnalyticsToggle from './TrackAnalyticsToggle.svelte';
import VectorStatusBadge from './VectorStatusBadge.svelte';

describe('VectorStatusBadge', () => {
	it('renders three vector states', () => {
		const { rerender } = render(VectorStatusBadge, { state: 'enabled' });
		expect(screen.getByText('Vector: enabled')).toBeInTheDocument();

		rerender({ state: 'disabled' });
		expect(screen.getByText('Vector: disabled')).toBeInTheDocument();

		rerender({ state: 'unavailable' });
		expect(screen.getByText('Vector: unavailable')).toBeInTheDocument();
	});
});

describe('TrackAnalyticsToggle', () => {
	it('fires callback when track analytics toggle changes', async () => {
		const onTrackAnalyticsChange = vi.fn();
		render(TrackAnalyticsToggle, {
			enabled: false,
			onTrackAnalyticsChange
		});

		await fireEvent.click(screen.getByLabelText('Track analytics events'));
		expect(onTrackAnalyticsChange).toHaveBeenCalledWith(true);
	});
});

describe('SearchPreviewHeader', () => {
	it('calls display-preferences and add-documents triggers', async () => {
		const onOpenDisplayPreferences = vi.fn();
		const onAddDocuments = vi.fn();

		render(SearchPreviewHeader, {
			vectorState: 'enabled',
			trackAnalyticsEnabled: false,
			onTrackAnalyticsChange: vi.fn(),
			onOpenDisplayPreferences,
			onAddDocuments
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Display preferences' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Add documents' }));

		expect(onOpenDisplayPreferences).toHaveBeenCalledTimes(1);
		expect(onAddDocuments).toHaveBeenCalledTimes(1);
	});
});
