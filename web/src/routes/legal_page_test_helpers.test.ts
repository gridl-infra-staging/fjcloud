import { afterEach, describe, expect, it } from 'vitest';
import { cleanup } from '@testing-library/svelte';

import {
	BETA_FEEDBACK_MAILTO,
	LEGAL_EFFECTIVE_DATE_TEXT,
	LEGAL_ENTITY_NAME,
	LEGAL_SUPPORT_MAILTO,
	SUPPORT_EMAIL
} from '$lib/format';
import { SHARED_LEGAL_PAGE_CONTRACT } from '../../tests/fixtures/legal_page_contract';
import {
	assertLegalPagePresentationContract,
	assertSharedLegalPageContract
} from './legal_page_test_helpers';

afterEach(cleanup);

function setLegalPageDom(forbiddenMarker?: string): void {
	document.body.innerHTML = `
		<div>
			<p>Public beta.</p>
			<a href="/beta">Learn about the beta</a>
			<a href="${BETA_FEEDBACK_MAILTO}">Send feedback</a>
			<a href="${LEGAL_SUPPORT_MAILTO}">Support</a>
			<nav aria-label="Legal">
				<a href="/terms">Terms</a>
				<a href="/privacy">Privacy</a>
				<a href="/dpa">DPA</a>
				<a href="/status">Status</a>
			</nav>
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

function setLegalPresentationDom(canvasClassName = 'bg-[#9fd8d2]'): void {
	document.body.innerHTML = `
		<div class="min-h-screen ${canvasClassName} text-[#1f1b18]">
			<main data-testid="public-legal-shell" class="mx-auto max-w-4xl px-6 py-12">
				<article class="mt-6 space-y-8 rounded-3xl border border-[#e3d7bf] bg-[#fff8ea] p-8 shadow-sm">
					<header class="space-y-4">
						<h1 class="text-3xl font-black text-[#1f1b18] sm:text-4xl">Terms of Service</h1>
					</header>
					<section class="space-y-3">
						<p class="leading-7 text-[#4b4640]">Body copy</p>
						<a class="font-semibold text-[#b83f5f] underline hover:text-[#8d2842]" href="/terms">
							Terms
						</a>
					</section>
				</article>
			</main>
		</div>
	`;
}

describe('assertLegalPagePresentationContract shell contract', () => {
	it('passes when the legal shell retains teal canvas styling', () => {
		setLegalPresentationDom();
		expect(() => assertLegalPagePresentationContract('Terms of Service')).not.toThrow();
	});

	it('fails when the legal shell teal canvas class is missing', () => {
		setLegalPresentationDom('bg-white');
		expect(() => assertLegalPagePresentationContract('Terms of Service')).toThrow();
	});
});
