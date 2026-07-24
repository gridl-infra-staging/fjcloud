import type { RecommendationRequest, RecommendationsBatchRequest } from '$lib/api/types';
import type {
	EditorDialogFieldSchema,
	EditorDialogValues
} from '$lib/components/EditorDialog.types';
import {
	DEFAULT_RECOMMENDATION_MODEL,
	metadataForModel,
	RECOMMENDATION_MODELS,
	type RecommendationModelId
} from './model_metadata';

export type RecommendationConfig = {
	model: RecommendationModelId;
	objectID: string;
	facetName: string;
	facetValue: string;
	threshold: number;
	maxRecommendations: number;
};

const DEFAULT_THRESHOLD = 0;
const DEFAULT_MAX_RECOMMENDATIONS = 5;

function recommendationModelIdFromUnknown(value: unknown): RecommendationModelId | null {
	if (typeof value !== 'string') {
		return null;
	}
	const matchingModel = RECOMMENDATION_MODELS.find((model) => model.id === value);
	return matchingModel?.id ?? null;
}

export function defaultRecommendationConfig(): RecommendationConfig {
	return {
		model: DEFAULT_RECOMMENDATION_MODEL,
		objectID: '',
		facetName: '',
		facetValue: '',
		threshold: DEFAULT_THRESHOLD,
		maxRecommendations: DEFAULT_MAX_RECOMMENDATIONS
	};
}

function stringValueOrFallback(value: unknown, fallback: string): string {
	return typeof value === 'string' ? value : fallback;
}

function numberValueOrFallback(value: unknown, fallback: number): number {
	return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
}

function modelFromUnknown(value: unknown, fallback: RecommendationModelId): RecommendationModelId {
	return recommendationModelIdFromUnknown(value) ?? fallback;
}

type RecommendationFieldReaders = {
	objectID: () => string;
	facetName: () => string;
	facetValue: () => string;
};

function applyModelSpecificRequestFields(
	request: RecommendationRequest,
	model: RecommendationModelId,
	fieldReaders: RecommendationFieldReaders
): void {
	const modelMetadata = metadataForModel(model);

	if (modelMetadata.requiresObjectID) {
		request.objectID = fieldReaders.objectID();
	}

	if (modelMetadata.requiresFacetName) {
		request.facetName = fieldReaders.facetName();
		request.facetValue = fieldReaders.facetValue();
	}
}

function requireFiniteNumber(value: unknown, fieldName: string): number {
	if (typeof value !== 'number' || !Number.isFinite(value)) {
		throw new Error(`${fieldName} must be a finite number`);
	}
	return value;
}

function requirePositiveInteger(value: unknown, fieldName: string): number {
	const numericValue = requireFiniteNumber(value, fieldName);
	if (!Number.isInteger(numericValue) || numericValue < 1) {
		throw new Error(`${fieldName} must be a positive integer`);
	}
	return numericValue;
}

function requireTrimmedString(value: unknown, fieldName: string): string {
	if (typeof value !== 'string') {
		throw new Error(`${fieldName} must be a string`);
	}
	const trimmedValue = value.trim();
	if (trimmedValue.length === 0) {
		throw new Error(`${fieldName} is required`);
	}
	return trimmedValue;
}

export function recommendationConfigFromDialogValues(
	values: EditorDialogValues,
	currentConfig: RecommendationConfig
): RecommendationConfig {
	const model = modelFromUnknown(values.model, currentConfig.model);
	return {
		model,
		objectID: stringValueOrFallback(values.objectID, currentConfig.objectID),
		facetName: stringValueOrFallback(values.facetName, currentConfig.facetName),
		facetValue: stringValueOrFallback(values.facetValue, currentConfig.facetValue),
		threshold: numberValueOrFallback(values.threshold, currentConfig.threshold),
		maxRecommendations: numberValueOrFallback(
			values.maxRecommendations,
			currentConfig.maxRecommendations
		)
	};
}

export function recommendationRequestFromConfig(
	indexName: string,
	config: RecommendationConfig
): RecommendationRequest {
	const request: RecommendationRequest = {
		indexName,
		model: config.model,
		threshold: config.threshold,
		maxRecommendations: config.maxRecommendations
	};

	applyModelSpecificRequestFields(request, config.model, {
		objectID: () => config.objectID.trim(),
		facetName: () => config.facetName.trim(),
		facetValue: () => config.facetValue.trim()
	});
	return request;
}

export function sanitizeRecommendationRequest(
	indexName: string,
	request: unknown
): RecommendationRequest {
	if (!request || typeof request !== 'object' || Array.isArray(request)) {
		throw new Error('request.requests[0] must be an object');
	}

	const record = request as Record<string, unknown>;
	const model = recommendationModelIdFromUnknown(record.model);
	if (!model) {
		throw new Error('request.requests[0].model is invalid');
	}

	const normalizedRequest: RecommendationRequest = {
		indexName,
		model,
		threshold: requireFiniteNumber(record.threshold, 'request.requests[0].threshold'),
		maxRecommendations: requirePositiveInteger(
			record.maxRecommendations,
			'request.requests[0].maxRecommendations'
		)
	};

	applyModelSpecificRequestFields(normalizedRequest, model, {
		objectID: () => requireTrimmedString(record.objectID, 'request.requests[0].objectID'),
		facetName: () => requireTrimmedString(record.facetName, 'request.requests[0].facetName'),
		facetValue: () => requireTrimmedString(record.facetValue, 'request.requests[0].facetValue')
	});
	return normalizedRequest;
}

export function recommendationsBatchRequestFromConfig(
	indexName: string,
	config: RecommendationConfig
): RecommendationsBatchRequest {
	return { requests: [recommendationRequestFromConfig(indexName, config)] };
}

export function serializeRecommendationsBatchRequest(
	indexName: string,
	config: RecommendationConfig
): string {
	return JSON.stringify(recommendationsBatchRequestFromConfig(indexName, config));
}

function dialogModelFromValues(values: EditorDialogValues): RecommendationModelId {
	return modelFromUnknown(values.model, DEFAULT_RECOMMENDATION_MODEL);
}

function dialogModelMetadata(values: EditorDialogValues) {
	return metadataForModel(dialogModelFromValues(values));
}

function showObjectIDField(values: EditorDialogValues): boolean {
	return dialogModelMetadata(values).requiresObjectID;
}

function showFacetFields(values: EditorDialogValues): boolean {
	return dialogModelMetadata(values).requiresFacetName;
}

export function recommendationConfigEditorSchema(): EditorDialogFieldSchema[] {
	return [
		{
			type: 'select',
			name: 'model',
			label: 'Model',
			required: true,
			options: RECOMMENDATION_MODELS.map((model) => ({ value: model.id, label: model.label }))
		},
		{
			type: 'text',
			name: 'objectID',
			label: 'Object ID',
			required: true,
			visible: showObjectIDField
		},
		{
			type: 'text',
			name: 'facetName',
			label: 'Facet Name',
			required: true,
			visible: showFacetFields
		},
		{
			type: 'text',
			name: 'facetValue',
			label: 'Facet Value',
			required: true,
			visible: showFacetFields
		},
		{
			type: 'number',
			name: 'threshold',
			label: 'Threshold',
			required: true
		},
		{
			type: 'number',
			name: 'maxRecommendations',
			label: 'Max Recommendations',
			required: true
		}
	];
}
