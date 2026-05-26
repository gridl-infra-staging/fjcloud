import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';

import HybridSearchControls from './HybridSearchControls.svelte';

describe('HybridSearchControls', () => {
	it('stays hidden when vector capability or embedder count is missing', () => {
		const { rerender } = render(HybridSearchControls, {
			capabilities: { vectorSearch: false },
			embedderCount: 2,
			enabled: false
		});

		expect(screen.queryByTestId('hybrid-search-controls')).not.toBeInTheDocument();

		rerender({ capabilities: { vectorSearch: true }, embedderCount: 0, enabled: false });
		expect(screen.queryByTestId('hybrid-search-controls')).not.toBeInTheDocument();
	});

	it('renders and toggles when vectorSearch is available and embedders exist', async () => {
		const onHybridEnabledChange = vi.fn();
		render(HybridSearchControls, {
			capabilities: { vectorSearch: true },
			embedderCount: 1,
			enabled: false,
			onHybridEnabledChange
		});

		expect(screen.getByTestId('hybrid-search-controls')).toBeInTheDocument();
		await fireEvent.click(screen.getByLabelText('Enable hybrid search'));
		expect(onHybridEnabledChange).toHaveBeenCalledWith(true);
	});
});
