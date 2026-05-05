import { afterEach, describe, expect, it } from 'vitest';
import { cleanup } from '@testing-library/svelte';

import {
	LEGAL_EFFECTIVE_DATE_TEXT,
	LEGAL_ENTITY_NAME,
	LEGAL_SUPPORT_MAILTO,
	SUPPORT_EMAIL
} from '$lib/format';
import { SHARED_LEGAL_PAGE_CONTRACT } from '../../tests/fixtures/legal_page_contract';
import { assertSharedLegalPageContract } from './legal_page_test_helpers';

afterEach(cleanup);

function setLegalPageDom(forbiddenMarker?: string): void {
	document.body.innerHTML = `
		<div>
			<p>${LEGAL_EFFECTIVE_DATE_TEXT}</p>
			<a href="/">Back to Flapjack Cloud</a>
			<a href="${LEGAL_SUPPORT_MAILTO}">${SUPPORT_EMAIL}</a>
			<p>${LEGAL_ENTITY_NAME}</p>
			${forbiddenMarker ? `<p>${forbiddenMarker}</p>` : ''}
		</div>
	`;
}

const forbiddenFinalizedCopyMarkers = SHARED_LEGAL_PAGE_CONTRACT.filter(
	(check): check is { kind: 'absent-text'; text: string } => check.kind === 'absent-text'
).map((check) => check.text);

describe('assertSharedLegalPageContract finalized contract', () => {
	it('passes when the finalized shared contract is present', () => {
		setLegalPageDom();
		expect(() => assertSharedLegalPageContract()).not.toThrow();
	});

	it.each(forbiddenFinalizedCopyMarkers)(
		'fails when prohibited finalized-copy marker "%s" is still present',
		(marker) => {
			setLegalPageDom(marker);
			expect(() => assertSharedLegalPageContract()).toThrow();
		}
	);
});
