import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';
import { SUPPORT_EMAIL } from '$lib/format';
import { buildBoundaryCopy } from './recovery-copy';
import SupportReferenceBlock from './SupportReferenceBlock.svelte';

describe('SupportReferenceBlock', () => {
	it('renders one support reference and uses SUPPORT_EMAIL for the mailto link', () => {
		const boundaryCopy = buildBoundaryCopy(
			{ status: 404, errorMessage: 'Page missing', scope: 'public' },
			'web-abc123def456'
		);

		render(SupportReferenceBlock, { boundaryCopy });

		expect(screen.getAllByText('Support reference')).toHaveLength(1);
		expect(screen.getAllByText(/^web-[a-f0-9]{12}$/)).toHaveLength(1);
		expect(screen.getByRole('link', { name: SUPPORT_EMAIL })).toHaveAttribute(
			'href',
			expect.stringContaining(`mailto:${SUPPORT_EMAIL}`)
		);
	});
});
