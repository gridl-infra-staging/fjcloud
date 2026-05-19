import {
	BETA_FEEDBACK_MAILTO,
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
	{ kind: 'text', text: 'Public beta.' },
	{ kind: 'link', name: 'Learn about the beta', href: '/beta' },
	{ kind: 'link', name: 'Send feedback', href: BETA_FEEDBACK_MAILTO },
	{ kind: 'link', name: 'Support', href: LEGAL_SUPPORT_MAILTO },
	{ kind: 'text', text: LEGAL_EFFECTIVE_DATE_TEXT },
	{ kind: 'link', name: 'Back to Flapjack Cloud', href: '/' },
	{ kind: 'link', name: 'Terms', href: '/terms' },
	{ kind: 'link', name: 'Privacy', href: '/privacy' },
	{ kind: 'link', name: 'DPA', href: '/dpa' },
	{ kind: 'link', name: 'Status', href: '/status' },
	{ kind: 'link', name: SUPPORT_EMAIL, href: LEGAL_SUPPORT_MAILTO },
	{ kind: 'text', text: LEGAL_ENTITY_TEXT },
	{ kind: 'absent-text', text: '(Draft)' },
	{ kind: 'absent-text', text: '[REVIEW:' },
	{ kind: 'absent-text', text: 'TBD' }
];
