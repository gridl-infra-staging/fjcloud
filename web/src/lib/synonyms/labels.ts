import type { SynonymType } from '$lib/api/types';

export const SYNONYM_TYPE_LABELS: Record<SynonymType, string> = {
	synonym: 'Multi-way',
	onewaysynonym: 'One-way',
	altcorrection1: 'Alt. Correction 1',
	altcorrection2: 'Alt. Correction 2',
	placeholder: 'Placeholder'
};

export function synonymTypeLabel(type: SynonymType | string): string {
	return SYNONYM_TYPE_LABELS[type as SynonymType] ?? type;
}
