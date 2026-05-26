import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

const storageMocks = vi.hoisted(() => ({
	loadSearchDisplayPrefs: vi.fn().mockReturnValue({
		hitsPerPage: 20,
		highlightedAttributes: ['title']
	}),
	saveSearchDisplayPrefs: vi.fn()
}));

vi.mock('./display_prefs_storage', () => ({
	loadSearchDisplayPrefs: storageMocks.loadSearchDisplayPrefs,
	saveSearchDisplayPrefs: storageMocks.saveSearchDisplayPrefs
}));

import DisplayPreferencesModal from './DisplayPreferencesModal.svelte';

const modalSource = readFileSync(
	join(process.cwd(), 'src', 'lib', 'components', 'search', 'DisplayPreferencesModal.svelte'),
	'utf8'
);

afterEach(() => {
	cleanup();
});

describe('DisplayPreferencesModal', () => {
	it('imports canonical display_prefs_storage owner with no dialog-wrapper dependency', () => {
		expect(modalSource).toContain('./display_prefs_storage');
		expect(modalSource).not.toContain('ConfirmDialog');
		expect(modalSource).not.toContain('EditorDialog');
	});

	it('loads and saves preferences through Stage 3 storage helpers', async () => {
		const onClose = vi.fn();
		render(DisplayPreferencesModal, {
			open: true,
			onClose
		});

		expect(storageMocks.loadSearchDisplayPrefs).toHaveBeenCalledTimes(1);

		await fireEvent.input(screen.getByLabelText('Hits per page'), {
			target: { value: '30' }
		});
		await fireEvent.click(screen.getByLabelText('Highlight body'));
		await fireEvent.click(screen.getByRole('button', { name: 'Save preferences' }));

		expect(storageMocks.saveSearchDisplayPrefs).toHaveBeenCalledWith({
			hitsPerPage: 30,
			highlightedAttributes: ['title', 'body']
		});
		expect(onClose).toHaveBeenCalledTimes(1);
	});
});
