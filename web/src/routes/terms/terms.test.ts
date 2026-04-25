import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';

import TermsPage from './+page.svelte';
import {
	assertSharedLegalPageContract,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

afterEach(cleanup);

describe('Terms page legal stub contract', () => {
	it('pins the draft terms legal contract for Stage 2 implementation', () => {
		render(TermsPage);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Terms of Service (Draft) — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Terms of Service (Draft)');
		assertUniqueVisibleText('[REVIEW: governing law state/country]');
	});
});
