import {
	LEGAL_EFFECTIVE_DATE_TEXT,
	LEGAL_ENTITY_NAME,
	LEGAL_SUPPORT_MAILTO,
	SUPPORT_EMAIL
} from '../../src/lib/format';

export const LEGAL_ENTITY_TEXT = LEGAL_ENTITY_NAME;

export type SharedLegalPageContractCheck =
	| { kind: 'text'; text: string }
	| { kind: 'link'; name: string; href: string }
	| { kind: 'absent-text'; text: string };

export const SHARED_LEGAL_PAGE_CONTRACT: readonly SharedLegalPageContractCheck[] = [
	{ kind: 'text', text: LEGAL_EFFECTIVE_DATE_TEXT },
	{ kind: 'link', name: 'Back to Flapjack Cloud', href: '/' },
	{ kind: 'link', name: SUPPORT_EMAIL, href: LEGAL_SUPPORT_MAILTO },
	{ kind: 'text', text: LEGAL_ENTITY_TEXT },
	{ kind: 'absent-text', text: '(Draft)' },
	{ kind: 'absent-text', text: '[REVIEW:' },
	{ kind: 'absent-text', text: 'TBD' }
];
