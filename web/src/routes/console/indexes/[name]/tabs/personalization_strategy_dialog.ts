import type {
	PersonalizationEventScoring,
	PersonalizationFacetScoring,
	PersonalizationStrategy
} from '$lib/api/types';
import type {
	EditorDialogFieldSchema,
	EditorDialogValues
} from '$lib/components/EditorDialog.types';

const STRATEGY_SCORE_MIN = 0;
const STRATEGY_SCORE_MAX = 100;
export const PERSONALIZATION_STRATEGY_MAX_ROWS = 15;

const EVENT_TYPE_OPTIONS: PersonalizationEventScoring['eventType'][] = [
	'click',
	'conversion',
	'view'
];

const EVENT_TYPE_SELECT_OPTIONS = EVENT_TYPE_OPTIONS.map((eventType) => ({
	value: eventType,
	label: eventType
}));

export const defaultPersonalizationStrategy: PersonalizationStrategy = {
	eventsScoring: [
		{ eventName: 'Product viewed', eventType: 'view', score: 10 },
		{ eventName: 'Product purchased', eventType: 'conversion', score: 50 }
	],
	facetsScoring: [
		{ facetName: 'brand', score: 70 },
		{ facetName: 'category', score: 30 }
	],
	personalizationImpact: 75
};

function cloneDefaultPersonalizationStrategy(): PersonalizationStrategy {
	return {
		eventsScoring: defaultPersonalizationStrategy.eventsScoring.map((eventRow) => ({
			...eventRow
		})),
		facetsScoring: defaultPersonalizationStrategy.facetsScoring.map((facetRow) => ({
			...facetRow
		})),
		personalizationImpact: defaultPersonalizationStrategy.personalizationImpact
	};
}

export const personalizationStrategyDialogSchema: EditorDialogFieldSchema[] = [
	{
		type: 'array',
		name: 'eventsScoring',
		label: 'Event scoring',
		required: true,
		addLabel: 'Add event score',
		maxItems: PERSONALIZATION_STRATEGY_MAX_ROWS,
		item: {
			type: 'group',
			fields: [
				{ type: 'text', name: 'eventName', label: 'Event name', required: true, maxLength: 120 },
				{
					type: 'select',
					name: 'eventType',
					label: 'Event type',
					required: true,
					options: EVENT_TYPE_SELECT_OPTIONS
				},
				{
					type: 'number',
					name: 'score',
					label: 'Score',
					required: true,
					integer: true,
					min: STRATEGY_SCORE_MIN,
					max: STRATEGY_SCORE_MAX
				}
			]
		}
	},
	{
		type: 'array',
		name: 'facetsScoring',
		label: 'Facet scoring',
		required: true,
		addLabel: 'Add facet score',
		maxItems: PERSONALIZATION_STRATEGY_MAX_ROWS,
		item: {
			type: 'group',
			fields: [
				{ type: 'text', name: 'facetName', label: 'Facet name', required: true, maxLength: 120 },
				{
					type: 'number',
					name: 'score',
					label: 'Score',
					required: true,
					integer: true,
					min: STRATEGY_SCORE_MIN,
					max: STRATEGY_SCORE_MAX
				}
			]
		}
	},
	{
		type: 'number',
		name: 'personalizationImpact',
		label: 'Personalization impact',
		required: true,
		integer: true,
		min: STRATEGY_SCORE_MIN,
		max: STRATEGY_SCORE_MAX
	}
];

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isMissingPersonalizationStrategy(value: unknown): boolean {
	return value == null || (isRecord(value) && Object.keys(value).length === 0);
}

function parseNonEmptyString(value: unknown, path: string): string {
	if (typeof value !== 'string' || value.trim().length === 0) {
		throw new Error(`${path} is required`);
	}
	return value.trim();
}

function parseIntegerInRange(value: unknown, path: string): number {
	if (typeof value !== 'number' || Number.isNaN(value) || !Number.isInteger(value)) {
		throw new Error(`${path} must be an integer`);
	}
	if (value < STRATEGY_SCORE_MIN || value > STRATEGY_SCORE_MAX) {
		throw new Error(`${path} must be between ${STRATEGY_SCORE_MIN} and ${STRATEGY_SCORE_MAX}`);
	}
	return value;
}

function parseEventType(value: unknown, path: string): PersonalizationEventScoring['eventType'] {
	if (typeof value !== 'string' || !EVENT_TYPE_OPTIONS.includes(value as never)) {
		throw new Error(`${path} must be one of ${EVENT_TYPE_OPTIONS.join(', ')}`);
	}
	return value as PersonalizationEventScoring['eventType'];
}

function parseEventsScoring(value: unknown): PersonalizationEventScoring[] {
	if (!Array.isArray(value)) {
		throw new Error('eventsScoring must be an array');
	}
	if (value.length > PERSONALIZATION_STRATEGY_MAX_ROWS) {
		throw new Error(`eventsScoring must include at most ${PERSONALIZATION_STRATEGY_MAX_ROWS} rows`);
	}

	return value.map((row, index) => {
		if (!isRecord(row)) {
			throw new Error(`eventsScoring[${index}] must be an object`);
		}
		return {
			eventName: parseNonEmptyString(row.eventName, `eventsScoring[${index}].eventName`),
			eventType: parseEventType(row.eventType, `eventsScoring[${index}].eventType`),
			score: parseIntegerInRange(row.score, `eventsScoring[${index}].score`)
		};
	});
}

function parseFacetsScoring(value: unknown): PersonalizationFacetScoring[] {
	if (!Array.isArray(value)) {
		throw new Error('facetsScoring must be an array');
	}
	if (value.length > PERSONALIZATION_STRATEGY_MAX_ROWS) {
		throw new Error(`facetsScoring must include at most ${PERSONALIZATION_STRATEGY_MAX_ROWS} rows`);
	}

	return value.map((row, index) => {
		if (!isRecord(row)) {
			throw new Error(`facetsScoring[${index}] must be an object`);
		}
		return {
			facetName: parseNonEmptyString(row.facetName, `facetsScoring[${index}].facetName`),
			score: parseIntegerInRange(row.score, `facetsScoring[${index}].score`)
		};
	});
}

export function parsePersonalizationStrategy(value: unknown): PersonalizationStrategy {
	if (!isRecord(value)) {
		throw new Error(
			"Strategy isn't valid JSON yet. Use a JSON object with eventsScoring, facetsScoring, and personalizationImpact."
		);
	}

	return {
		eventsScoring: parseEventsScoring(value.eventsScoring),
		facetsScoring: parseFacetsScoring(value.facetsScoring),
		personalizationImpact: parseIntegerInRange(value.personalizationImpact, 'personalizationImpact')
	};
}

export function normalizePersonalizationStrategy(value: unknown): {
	strategy: PersonalizationStrategy;
	error: string;
	invalidState: PersonalizationStrategyInvalidState | null;
} {
	if (isMissingPersonalizationStrategy(value)) {
		return {
			strategy: cloneDefaultPersonalizationStrategy(),
			error: '',
			invalidState: null
		};
	}

	try {
		return { strategy: parsePersonalizationStrategy(value), error: '', invalidState: null };
	} catch (error) {
		const technicalMessage =
			error instanceof Error ? error.message : 'Invalid personalization strategy';
		const exampleStrategy = cloneDefaultPersonalizationStrategy();
		return {
			strategy: exampleStrategy,
			error: technicalMessage,
			invalidState: {
				technicalMessage,
				exampleStrategy
			}
		};
	}
}

export type PersonalizationStrategyInvalidState = {
	technicalMessage: string;
	exampleStrategy: PersonalizationStrategy;
};

export function strategyToDialogValue(strategy: PersonalizationStrategy): EditorDialogValues {
	return {
		eventsScoring: strategy.eventsScoring.map((eventRow) => ({
			eventName: eventRow.eventName,
			eventType: eventRow.eventType,
			score: eventRow.score
		})),
		facetsScoring: strategy.facetsScoring.map((facetRow) => ({
			facetName: facetRow.facetName,
			score: facetRow.score
		})),
		personalizationImpact: strategy.personalizationImpact
	};
}

export function strategyFromDialogValue(value: EditorDialogValues): PersonalizationStrategy {
	return parsePersonalizationStrategy(value);
}

export function serializePersonalizationStrategy(strategy: PersonalizationStrategy): string {
	return JSON.stringify(strategy, null, 2);
}
