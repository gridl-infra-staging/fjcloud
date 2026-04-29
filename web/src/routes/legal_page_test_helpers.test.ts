import { afterEach, describe, expect, it } from "vitest";
import { cleanup } from "@testing-library/svelte";

import {
	BETA_FEEDBACK_MAILTO,
	LEGAL_BADGE_LABEL,
	LEGAL_DRAFT_BANNER_TEXT,
	LEGAL_EFFECTIVE_DATE_TEXT,
	LEGAL_ENTITY_NAME,
	SUPPORT_EMAIL
} from "$lib/format";
import { assertSharedLegalPageContract } from "./legal_page_test_helpers";

afterEach(cleanup);

function setLegalPageDom(badgeLabel: string, includeUnrelatedPaidBetaText: boolean): void {
	document.body.innerHTML = `
		<div>
			<p>
				<span>${badgeLabel}</span>
				<span>${LEGAL_DRAFT_BANNER_TEXT}</span>
			</p>
			${includeUnrelatedPaidBetaText ? `<p>${LEGAL_BADGE_LABEL}</p>` : ""}
			<p>${LEGAL_EFFECTIVE_DATE_TEXT}</p>
			<a href="/">Back to Flapjack Cloud</a>
			<a href="${BETA_FEEDBACK_MAILTO}">${SUPPORT_EMAIL}</a>
			<p>${LEGAL_ENTITY_NAME}</p>
		</div>
	`;
}

describe("assertSharedLegalPageContract badge contract", () => {
	it("fails when only unrelated page text matches Paid Beta but banner pill label is wrong", () => {
		setLegalPageDom("Draft", true);
		expect(() => assertSharedLegalPageContract()).toThrow();
	});

	it("passes when the banner pill itself renders the Paid Beta label", () => {
		setLegalPageDom(LEGAL_BADGE_LABEL, false);
		expect(() => assertSharedLegalPageContract()).not.toThrow();
	});
});
