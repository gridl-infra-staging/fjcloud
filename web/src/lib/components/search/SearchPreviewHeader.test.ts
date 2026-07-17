import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewHeader from './SearchPreviewHeader.svelte';
import TrackAnalyticsToggle from './TrackAnalyticsToggle.svelte';
import VectorStatusBadge from './VectorStatusBadge.svelte';

afterEach(() => {
	cleanup();
});

describe('VectorStatusBadge', () => {
	it('renders three vector states', () => {
		const { rerender } = render(VectorStatusBadge, { state: 'enabled' });
		expect(screen.getByText('Vector: enabled')).toBeInTheDocument();

		rerender({ state: 'disabled' });
		expect(screen.getByText('Vector: disabled')).toBeInTheDocument();

		rerender({ state: 'unavailable' });
		const unavailable = screen.getByText('Vector: unavailable');
		expect(unavailable).toBeInTheDocument();
		expect(unavailable).toHaveClass('bg-flapjack-yellow/35', 'text-flapjack-plum');
	});
});

describe('TrackAnalyticsToggle', () => {
	it('fires callback when track analytics toggle changes', async () => {
		const onTrackAnalyticsChange = vi.fn();
		render(TrackAnalyticsToggle, {
			enabled: false,
			onTrackAnalyticsChange
		});

		await fireEvent.click(screen.getByLabelText('Record preview activity in Analytics'));
		expect(onTrackAnalyticsChange).toHaveBeenCalledWith(true);
	});
});

describe('SearchPreviewHeader', () => {
	it('explains preview recording semantics and exposes delivery status', async () => {
		render(SearchPreviewHeader, {
			vectorState: 'enabled',
			trackAnalyticsEnabled: false,
			onTrackAnalyticsChange: vi.fn(),
			analyticsStatusMessage: 'Recorded result open.',
			onAddDocuments: vi.fn()
		});

		expect(screen.getByTestId('search-preview-header')).toContainElement(
			screen.getByLabelText('Record preview activity in Analytics')
		);

		const tooltipTrigger = screen.getByRole('button', {
			name: 'About Track Analytics'
		});
		await fireEvent.click(tooltipTrigger);

		expect(screen.getByRole('tooltip')).toHaveTextContent(
			'When enabled, preview searches and explicit result opens are recorded for this index and may appear in Analytics. When disabled, preview searches are excluded.'
		);
		expect(screen.getByRole('status')).toHaveTextContent('Recorded result open.');
	});

	it('keeps the header focused on search operations without a nested Search heading or preferences dialog', async () => {
		const onAddDocuments = vi.fn();

		render(SearchPreviewHeader, {
			vectorState: 'enabled',
			trackAnalyticsEnabled: false,
			onTrackAnalyticsChange: vi.fn(),
			onAddDocuments
		});

		expect(screen.queryByRole('heading', { name: 'Search' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Display preferences' })).not.toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: 'Add documents' }));

		expect(onAddDocuments).toHaveBeenCalledTimes(1);
	});
});
