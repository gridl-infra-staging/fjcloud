import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';

import PrivacyPage from './+page.svelte';
import {
	assertSharedLegalPageContract,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

afterEach(cleanup);

describe('Privacy page legal stub contract', () => {
	it('pins the draft privacy legal contract for Stage 2 implementation', () => {
		render(PrivacyPage);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Privacy Policy (Draft) — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Privacy Policy (Draft)');
		assertUniqueVisibleText('[REVIEW: COPPA applicability]');
	});
});
