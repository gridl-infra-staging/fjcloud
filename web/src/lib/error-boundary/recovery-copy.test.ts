import { describe, expect, it } from 'vitest';
import { SUPPORT_EMAIL } from '$lib/format';
import { buildBoundaryCopy } from './recovery-copy';

describe('buildBoundaryCopy', () => {
	it('derives a deterministic support reference for identical boundary input', () => {
		const firstCopy = buildBoundaryCopy({
			status: 500,
			errorMessage: 'Internal server error',
			scope: 'public'
		});
		const secondCopy = buildBoundaryCopy({
			status: 500,
			errorMessage: 'Internal server error',
			scope: 'public'
		});

		expect(firstCopy.supportReference).toMatch(/^web-[a-f0-9]{12}$/);
		expect(secondCopy.supportReference).toBe(firstCopy.supportReference);
		expect(firstCopy.supportEmail).toBe(SUPPORT_EMAIL);
		expect(firstCopy.supportMailtoHref).toContain(
			encodeURIComponent(`Flapjack Cloud support reference ${firstCopy.supportReference}`)
		);
		expect(firstCopy.supportMailtoHref).toContain(`mailto:${SUPPORT_EMAIL}`);
	});

	it('preserves safe 4xx messages and attaches a support reference block', () => {
		const copy = buildBoundaryCopy(
			{ status: 403, errorMessage: 'Your request cannot be completed right now', scope: 'public' },
			'web-abc123def456'
		);

		expect(copy.description).toBe('Your request cannot be completed right now');
		expect(copy.supportReference).toBe('web-abc123def456');
		expect(copy.supportEmail).toBe(SUPPORT_EMAIL);
		expect(copy.supportMailtoHref).toContain(
			encodeURIComponent('Flapjack Cloud support reference web-abc123def456')
		);
	});

	it('suppresses unsafe infrastructure details while keeping the support reference available', () => {
		const copy = buildBoundaryCopy(
			{
				status: 500,
				errorMessage: 'PG::ConnectionBad: could not connect to 127.0.0.1:5432',
				scope: 'dashboard'
			},
			'web-fedcba654321'
		);

		expect(copy.description).toBe(
			"We're experiencing a temporary issue. Please try again shortly or check our status page for updates."
		);
		expect(copy.supportReference).toBe('web-fedcba654321');
	});

	it('keeps customer-facing copy independent from backend request-id-like error details', () => {
		const firstCopy = buildBoundaryCopy(
			{
				status: 500,
				errorMessage: 'req-backend-111 PG::ConnectionBad while reaching postgres.internal:5432',
				scope: 'dashboard'
			},
			'web-1a2b3c4d5e6f'
		);
		const secondCopy = buildBoundaryCopy(
			{
				status: 500,
				errorMessage: 'req-backend-222 Traceback ECONNREFUSED to 10.0.0.12:5432',
				scope: 'dashboard'
			},
			'web-1a2b3c4d5e6f'
		);

		expect(firstCopy.supportReference).toBe('web-1a2b3c4d5e6f');
		expect(secondCopy.supportReference).toBe('web-1a2b3c4d5e6f');
		expect(firstCopy.description).toBe(secondCopy.description);
		expect(firstCopy.description).not.toContain('req-backend-111');
		expect(secondCopy.description).not.toContain('req-backend-222');
		expect(firstCopy.supportMailtoHref).toBe(secondCopy.supportMailtoHref);
	});

	it('keeps deterministic fallback support references stable across internal-only 5xx detail changes', () => {
		const firstCopy = buildBoundaryCopy({
			status: 500,
			errorMessage: 'PG::ConnectionBad: could not connect to 127.0.0.1:5432',
			scope: 'public'
		});
		const secondCopy = buildBoundaryCopy({
			status: 500,
			errorMessage: 'Traceback: ECONNREFUSED while reaching postgres.internal:5432',
			scope: 'public'
		});

		expect(firstCopy.description).toBe(secondCopy.description);
		expect(firstCopy.supportReference).toBe(secondCopy.supportReference);
	});
});
