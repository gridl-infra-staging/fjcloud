import { describe, it, expect } from 'vitest';
import { SYNONYM_TYPE_LABELS, synonymTypeLabel } from './labels';

describe('synonym labels', () => {
	it('exports the canonical human-readable labels by synonym type', () => {
		expect(SYNONYM_TYPE_LABELS).toEqual({
			synonym: 'Multi-way',
			onewaysynonym: 'One-way',
			altcorrection1: 'Alt. Correction 1',
			altcorrection2: 'Alt. Correction 2',
			placeholder: 'Placeholder'
		});
	});

	it('returns mapped label for known types and raw fallback for unknown values', () => {
		expect(synonymTypeLabel('synonym')).toBe('Multi-way');
		expect(synonymTypeLabel('onewaysynonym')).toBe('One-way');
		expect(synonymTypeLabel('placeholder')).toBe('Placeholder');
		expect(synonymTypeLabel('unmapped-type' as never)).toBe('unmapped-type');
	});
});
