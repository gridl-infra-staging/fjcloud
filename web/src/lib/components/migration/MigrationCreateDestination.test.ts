import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

import MigrationCreateDestination from './MigrationCreateDestination.svelte';
import { previewResponse, TARGET_ELIGIBILITY } from './migration_test_fixtures';

afterEach(cleanup);

describe('MigrationCreateDestination', () => {
	it('uses the parent-owned preview satisfaction gate to hide submit', () => {
		render(MigrationCreateDestination, {
			destination: {
				sourceName: 'source_products',
				name: 'source_products',
				error: null,
				replace: null
			},
			eligibility: {
				canCheck: true,
				checking: false,
				error: null,
				current: TARGET_ELIGIBILITY
			},
			preview: {
				result: previewResponse(),
				warnings: null,
				error: null,
				loading: false,
				supported: true,
				satisfied: false
			},
			review: {
				mode: 'create',
				admission: { title: 'Imports available', message: '', disablesStarts: false },
				submitError: null,
				submitDisabled: true,
				submitting: false
			},
			actions: {
				onDestinationInput: vi.fn(),
				onCheck: vi.fn(),
				onPreview: vi.fn(),
				onSubmit: vi.fn()
			}
		});

		expect(screen.queryByRole('button', { name: /^start import$/i })).not.toBeInTheDocument();
	});
});
