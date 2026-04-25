import {
	BETA_FEEDBACK_MAILTO,
	LEGAL_DRAFT_BANNER_TEXT,
	LEGAL_ENTITY_NAME,
	SUPPORT_EMAIL
} from '../../src/lib/format';

export const LEGAL_ENTITY_TEXT = LEGAL_ENTITY_NAME;

export type SharedLegalPageContractCheck =
	| { kind: 'text'; text: string }
	| { kind: 'link'; name: string; href: string };

export const SHARED_LEGAL_PAGE_CONTRACT: readonly SharedLegalPageContractCheck[] = [
	{ kind: 'text', text: LEGAL_DRAFT_BANNER_TEXT },
	{ kind: 'link', name: 'Back to Flapjack Cloud', href: '/' },
	{ kind: 'link', name: SUPPORT_EMAIL, href: BETA_FEEDBACK_MAILTO },
	{ kind: 'text', text: LEGAL_ENTITY_TEXT }
];
