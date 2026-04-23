/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/lib/utils/merchandising.ts.
 */
import type { Rule } from '$lib/api/types';

export interface MerchandisingPin {
	objectID: string;
	position: number;
}

export interface MerchandisingHide {
	objectID: string;
}

interface CreateMerchandisingRuleInput {
	query: string;
	description?: string;
	pins: MerchandisingPin[];
	hides: MerchandisingHide[];
	timestamp?: number;
}

function slugify(input: string): string {
	const slug = input
		.trim()
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '');

	return slug.length > 0 ? slug : 'query';
}

export function createMerchandisingRule({
	query,
	description,
	pins,
	hides,
	timestamp = Date.now()
}: CreateMerchandisingRuleInput): Rule {
	const consequence: Rule['consequence'] = {};
	if (pins.length > 0) {
		consequence.promote = pins.map((pin) => ({ objectID: pin.objectID, position: pin.position }));
	}
	if (hides.length > 0) {
		consequence.hide = hides.map((hide) => ({ objectID: hide.objectID }));
	}

	return {
		objectID: `merch-${slugify(query)}-${timestamp}`,
		conditions: [{ pattern: query, anchoring: 'is' }],
		consequence,
		description: description || `Merchandising: "${query}"`,
		enabled: true
	};
}
