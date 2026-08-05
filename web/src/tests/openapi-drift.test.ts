import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
	MIGRATION_PREVIEW_SOURCE_PROVIDERS,
	MIGRATION_PREVIEW_REPORT_CODES,
	MIGRATION_PREVIEW_REPORT_RESOURCES,
	MIGRATION_PREVIEW_REPORT_SEVERITIES
} from '$lib/api/types';

type JsonSchema = {
	type?: string | string[];
	required?: string[];
	properties?: Record<string, JsonSchema>;
	items?: JsonSchema;
	$ref?: string;
	oneOf?: JsonSchema[];
	enum?: string[];
	additionalProperties?: JsonSchema | boolean;
};

type OpenApiDocument = {
	components?: {
		schemas?: Record<string, JsonSchema>;
	};
	paths?: Record<string, Partial<Record<'get' | 'post', OpenApiOperation>>>;
};

type OpenApiOperation = {
	requestBody?: {
		content?: Record<string, { schema?: JsonSchema }>;
	};
	responses?: Record<
		string,
		{
			content?: Record<
				string,
				{
					schema?: JsonSchema;
				}
			>;
		}
	>;
};

type PrimitiveKind = 'string' | 'number' | 'integer' | 'boolean';

type PropertyDescriptor = { name: string; required?: boolean } & (
	| { kind: 'primitive'; type: PrimitiveKind }
	| { kind: 'nullablePrimitive'; type: PrimitiveKind }
	| { kind: 'nullableString' }
	| { kind: 'refArray'; ref: string }
	| { kind: 'primitiveArray'; type: PrimitiveKind }
	| { kind: 'ref'; ref: string }
	| { kind: 'nullableRef'; ref: string }
	| { kind: 'object' }
	| { kind: 'map' }
);

type SchemaDescriptor = {
	schemaName: string;
	properties: PropertyDescriptor[];
};

type ResponseDescriptor = {
	path: string;
	method: 'get' | 'post';
	status: string;
	ref: string;
};

type RequestDescriptor = Omit<ResponseDescriptor, 'status'>;

type EnumSchemaDescriptor = {
	schemaName: string;
	values: readonly string[];
};

type OneOfSchemaDescriptor = {
	schemaName: string;
	refs: readonly string[];
};

const openApiPath = resolve(
	dirname(fileURLToPath(import.meta.url)),
	'../../../docs/reference/openapi.json'
);
const openApi = JSON.parse(readFileSync(openApiPath, 'utf8')) as OpenApiDocument;

const schemaDescriptors: SchemaDescriptor[] = [
	{
		schemaName: 'LoginRequest',
		properties: [
			{ name: 'email', kind: 'primitive', type: 'string', required: true },
			{ name: 'password', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'RegisterRequest',
		properties: [
			{ name: 'name', kind: 'primitive', type: 'string', required: true },
			{ name: 'email', kind: 'primitive', type: 'string', required: true },
			{ name: 'password', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'AuthResponse',
		properties: [
			{ name: 'token', kind: 'primitive', type: 'string', required: true },
			{ name: 'customer_id', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'CreateIndexRequest',
		properties: [
			{ name: 'name', kind: 'primitive', type: 'string', required: true },
			{ name: 'region', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'IndexResponse',
		properties: [
			{ name: 'name', kind: 'primitive', type: 'string', required: true },
			{ name: 'region', kind: 'primitive', type: 'string', required: true },
			{ name: 'endpoint', kind: 'nullableString' },
			{ name: 'entries', kind: 'primitive', type: 'integer', required: true },
			{ name: 'data_size_bytes', kind: 'primitive', type: 'integer', required: true },
			{ name: 'status', kind: 'primitive', type: 'string', required: true },
			{ name: 'tier', kind: 'primitive', type: 'string', required: true },
			{ name: 'created_at', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'CustomerIndexMetricsResponse',
		properties: [
			{ name: 'index', kind: 'primitive', type: 'string', required: true },
			{ name: 'documents_count', kind: 'primitive', type: 'integer', required: true },
			{ name: 'storage_bytes', kind: 'primitive', type: 'integer', required: true },
			{ name: 'search_requests_total', kind: 'primitive', type: 'integer', required: true },
			{ name: 'write_operations_total', kind: 'primitive', type: 'integer', required: true },
			{ name: 'fetched_at', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'IndexInfrastructureResponse',
		properties: [
			{ name: 'index', kind: 'primitive', type: 'string', required: true },
			{ name: 'primary', kind: 'ref', ref: 'InfrastructurePrimary', required: true },
			{ name: 'replicas', kind: 'refArray', ref: 'InfrastructureReplica', required: true },
			{ name: 'footprint', kind: 'ref', ref: 'InfrastructureFootprint', required: true },
			{ name: 'headroom', kind: 'ref', ref: 'HeadroomStatus', required: true },
			{
				name: 'minimum_refresh_interval_seconds',
				kind: 'primitive',
				type: 'integer',
				required: true
			}
		]
	},
	{
		schemaName: 'InfrastructurePrimary',
		properties: [
			{ name: 'region', kind: 'primitive', type: 'string', required: true },
			{ name: 'status', kind: 'primitive', type: 'string', required: true },
			{ name: 'utilization', kind: 'nullableRef', ref: 'UtilizationBucket', required: true }
		]
	},
	{
		schemaName: 'InfrastructureReplica',
		properties: [
			{ name: 'region', kind: 'primitive', type: 'string', required: true },
			{ name: 'status', kind: 'primitive', type: 'string', required: true },
			{ name: 'lag_ops', kind: 'primitive', type: 'integer', required: true },
			{ name: 'utilization', kind: 'nullableRef', ref: 'UtilizationBucket', required: true }
		]
	},
	{
		schemaName: 'InfrastructureFootprint',
		properties: [
			{ name: 'documents_count', kind: 'primitive', type: 'integer', required: true },
			{ name: 'storage_bytes', kind: 'primitive', type: 'integer', required: true },
			{ name: 'search_requests_total', kind: 'primitive', type: 'integer', required: true },
			{ name: 'write_operations_total', kind: 'primitive', type: 'integer', required: true }
		]
	},
	{
		schemaName: 'EstimateLineItem',
		properties: [
			{ name: 'description', kind: 'primitive', type: 'string', required: true },
			{ name: 'quantity', kind: 'primitive', type: 'string', required: true },
			{ name: 'unit', kind: 'primitive', type: 'string', required: true },
			{ name: 'unit_price_cents', kind: 'primitive', type: 'string', required: true },
			{ name: 'amount_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'region', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'EstimatedBillResponse',
		properties: [
			{ name: 'month', kind: 'primitive', type: 'string', required: true },
			{ name: 'subtotal_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'total_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'line_items', kind: 'refArray', ref: 'EstimateLineItem', required: true },
			{ name: 'minimum_applied', kind: 'primitive', type: 'boolean', required: true }
		]
	},
	{
		schemaName: 'RegionUsageSummary',
		properties: [
			{ name: 'region', kind: 'primitive', type: 'string', required: true },
			{ name: 'search_requests', kind: 'primitive', type: 'integer', required: true },
			{ name: 'write_operations', kind: 'primitive', type: 'integer', required: true },
			{ name: 'avg_storage_gb', kind: 'primitive', type: 'number', required: true },
			{ name: 'avg_document_count', kind: 'primitive', type: 'integer', required: true }
		]
	},
	{
		schemaName: 'UsageSummaryResponse',
		properties: [
			{ name: 'month', kind: 'primitive', type: 'string', required: true },
			{ name: 'total_search_requests', kind: 'primitive', type: 'integer', required: true },
			{ name: 'total_write_operations', kind: 'primitive', type: 'integer', required: true },
			{ name: 'avg_storage_gb', kind: 'primitive', type: 'number', required: true },
			{ name: 'avg_document_count', kind: 'primitive', type: 'integer', required: true },
			{ name: 'by_region', kind: 'refArray', ref: 'RegionUsageSummary', required: true }
		]
	},
	{
		schemaName: 'LineItemResponse',
		properties: [
			{ name: 'id', kind: 'primitive', type: 'string', required: true },
			{ name: 'description', kind: 'primitive', type: 'string', required: true },
			{ name: 'quantity', kind: 'primitive', type: 'string', required: true },
			{ name: 'unit', kind: 'primitive', type: 'string', required: true },
			{ name: 'unit_price_cents', kind: 'primitive', type: 'string', required: true },
			{ name: 'amount_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'region', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'InvoiceListItem',
		properties: [
			{ name: 'id', kind: 'primitive', type: 'string', required: true },
			{ name: 'period_start', kind: 'primitive', type: 'string', required: true },
			{ name: 'period_end', kind: 'primitive', type: 'string', required: true },
			{ name: 'subtotal_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'total_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'status', kind: 'primitive', type: 'string', required: true },
			{ name: 'minimum_applied', kind: 'primitive', type: 'boolean', required: true },
			{ name: 'created_at', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'InvoiceDetailResponse',
		properties: [
			{ name: 'id', kind: 'primitive', type: 'string', required: true },
			{ name: 'customer_id', kind: 'primitive', type: 'string', required: true },
			{ name: 'period_start', kind: 'primitive', type: 'string', required: true },
			{ name: 'period_end', kind: 'primitive', type: 'string', required: true },
			{ name: 'subtotal_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'total_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'tax_cents', kind: 'primitive', type: 'integer', required: true },
			{ name: 'currency', kind: 'primitive', type: 'string', required: true },
			{ name: 'status', kind: 'primitive', type: 'string', required: true },
			{ name: 'minimum_applied', kind: 'primitive', type: 'boolean', required: true },
			{ name: 'stripe_invoice_id', kind: 'nullableString' },
			{ name: 'hosted_invoice_url', kind: 'nullableString' },
			{ name: 'pdf_url', kind: 'nullableString' },
			{ name: 'line_items', kind: 'refArray', ref: 'LineItemResponse', required: true },
			{ name: 'created_at', kind: 'primitive', type: 'string', required: true },
			{ name: 'finalized_at', kind: 'nullableString' },
			{ name: 'paid_at', kind: 'nullableString' }
		]
	},
	{
		schemaName: 'AlgoliaMigrationAvailabilityResponse',
		properties: [
			{ name: 'available', kind: 'primitive', type: 'boolean', required: true },
			{ name: 'reason', kind: 'nullableRef', ref: 'AlgoliaMigrationAvailabilityReason' },
			{ name: 'message', kind: 'primitive', type: 'string', required: true },
			{ name: 'capabilities', kind: 'ref', ref: 'AlgoliaMigrationCapabilities', required: true }
		]
	},
	{
		schemaName: 'AlgoliaMigrationCapabilities',
		properties: [
			{ name: 'cancel', kind: 'primitive', type: 'boolean', required: true },
			{ name: 'resume', kind: 'primitive', type: 'boolean', required: true },
			{ name: 'replace', kind: 'primitive', type: 'boolean', required: true }
		]
	},
	{
		schemaName: 'ListAlgoliaIndexesRequest',
		properties: [
			{ name: 'appId', kind: 'primitive', type: 'string', required: true },
			{ name: 'apiKey', kind: 'primitive', type: 'string', required: true },
			{ name: 'cursor', kind: 'nullableString' },
			{ name: 'hitsPerPage', kind: 'primitive', type: 'integer' }
		]
	},
	{
		schemaName: 'AlgoliaIndexMetadata',
		properties: [
			{ name: 'name', kind: 'primitive', type: 'string', required: true },
			{ name: 'entries', kind: 'primitive', type: 'integer', required: true },
			{ name: 'dataSize', kind: 'primitive', type: 'integer', required: true },
			{ name: 'fileSize', kind: 'primitive', type: 'integer', required: true },
			{ name: 'updatedAt', kind: 'primitive', type: 'string', required: true },
			{ name: 'lastBuildTimeS', kind: 'primitive', type: 'integer', required: true },
			{ name: 'pendingTask', kind: 'primitive', type: 'boolean', required: true },
			{ name: 'primary', kind: 'nullableString', required: true },
			{ name: 'replicas', kind: 'primitiveArray', type: 'string', required: true }
		]
	},
	{
		schemaName: 'AlgoliaSourceListResponse',
		properties: [
			{ name: 'items', kind: 'refArray', ref: 'AlgoliaIndexMetadata', required: true },
			{ name: 'nextCursor', kind: 'nullableString', required: true }
		]
	},
	{
		schemaName: 'AlgoliaMigrationPreviewRequest',
		properties: [
			{ name: 'appId', kind: 'primitive', type: 'string', required: true },
			{ name: 'apiKey', kind: 'primitive', type: 'string', required: true },
			{ name: 'sourceIndex', kind: 'primitive', type: 'string', required: true },
			{ name: 'targetIndex', kind: 'nullableString' },
			{ name: 'overwrite', kind: 'primitive', type: 'boolean' }
		]
	},
	{
		schemaName: 'MeilisearchMigrationPreviewRequest',
		properties: [
			{ name: 'endpoint', kind: 'primitive', type: 'string', required: true },
			{ name: 'apiKey', kind: 'primitive', type: 'string', required: true },
			{ name: 'sourceIndex', kind: 'primitive', type: 'string', required: true },
			{ name: 'targetIndex', kind: 'nullableString' },
			{ name: 'overwrite', kind: 'primitive', type: 'boolean' }
		]
	},
	{
		schemaName: 'MigrationPreviewReportEntry',
		properties: [
			{ name: 'severity', kind: 'ref', ref: 'MigrationPreviewReportSeverity', required: true },
			{ name: 'code', kind: 'ref', ref: 'MigrationPreviewReportCode', required: true },
			{ name: 'resource', kind: 'ref', ref: 'MigrationPreviewReportResource', required: true },
			{ name: 'pageIndex', kind: 'nullablePrimitive', type: 'integer' },
			{ name: 'itemIndex', kind: 'nullablePrimitive', type: 'integer' },
			{ name: 'jsonPath', kind: 'primitive', type: 'string', required: true }
		]
	},
	{
		schemaName: 'MigrationPreviewReportSummary',
		properties: [
			{ name: 'totalEntries', kind: 'primitive', type: 'integer', required: true },
			{ name: 'hardRejections', kind: 'primitive', type: 'integer', required: true },
			{ name: 'warnings', kind: 'primitive', type: 'integer', required: true },
			{ name: 'scopeGaps', kind: 'primitive', type: 'integer', required: true }
		]
	},
	{
		schemaName: 'MigrationPreviewReport',
		properties: [
			{ name: 'entries', kind: 'refArray', ref: 'MigrationPreviewReportEntry', required: true },
			{ name: 'summary', kind: 'ref', ref: 'MigrationPreviewReportSummary', required: true },
			{ name: 'reportDigest', kind: 'nullableString' }
		]
	},
	{
		schemaName: 'MigrationPreviewSourceCounts',
		properties: [
			{ name: 'indexes', kind: 'primitive', type: 'integer', required: true },
			{ name: 'records', kind: 'primitive', type: 'integer', required: true }
		]
	},
	{
		schemaName: 'MigrationPreviewResponse',
		properties: [
			{ name: 'report', kind: 'ref', ref: 'MigrationPreviewReport', required: true },
			{ name: 'sourceCounts', kind: 'ref', ref: 'MigrationPreviewSourceCounts', required: true }
		]
	}
];

const arrayResponseDescriptors: ResponseDescriptor[] = [
	{ path: '/indexes', method: 'get', status: '200', ref: 'IndexResponse' }
];

const objectResponseDescriptors: ResponseDescriptor[] = [
	{
		path: '/migration/{source_provider}/preview',
		method: 'post',
		status: '200',
		ref: 'MigrationPreviewResponse'
	},
	{
		// list-indexes 200 now returns the composite body owner, whose oneOf arms
		// are pinned by the ListSourceIndexesResponseBody oneOf descriptor below.
		path: '/migration/{source_provider}/list-indexes',
		method: 'post',
		status: '200',
		ref: 'ListSourceIndexesResponseBody'
	},
	{
		path: '/indexes/{name}/infrastructure',
		method: 'get',
		status: '200',
		ref: 'IndexInfrastructureResponse'
	}
];

const objectRequestDescriptors: RequestDescriptor[] = [
	{
		path: '/migration/{source_provider}/list-indexes',
		method: 'post',
		ref: 'ListSourceIndexesRequest'
	},
	{
		path: '/migration/{source_provider}/preview',
		method: 'post',
		ref: 'MigrationPreviewRequest'
	}
];

const enumSchemaDescriptors: EnumSchemaDescriptor[] = [
	{ schemaName: 'HeadroomStatus', values: ['comfortable', 'busy', 'approaching_limits'] },
	{ schemaName: 'UtilizationBucket', values: ['green', 'yellow', 'red'] },
	{ schemaName: 'MigrationPreviewReportSeverity', values: MIGRATION_PREVIEW_REPORT_SEVERITIES },
	{ schemaName: 'MigrationPreviewReportResource', values: MIGRATION_PREVIEW_REPORT_RESOURCES },
	{ schemaName: 'MigrationPreviewReportCode', values: MIGRATION_PREVIEW_REPORT_CODES }
];

const oneOfSchemaDescriptors: OneOfSchemaDescriptor[] = [
	{
		schemaName: 'ListSourceIndexesRequest',
		refs: ['ListAlgoliaIndexesRequest', 'ListMeilisearchIndexesRequest', 'ListTypesenseIndexesRequest']
	},
	{
		schemaName: 'ListSourceIndexesResponseBody',
		refs: ['AlgoliaSourceListResponse', 'ListSourceIndexesResponse']
	},
	{
		schemaName: 'MigrationPreviewRequest',
		refs: MIGRATION_PREVIEW_SOURCE_PROVIDERS.map(
			(sourceProvider) =>
				`${sourceProvider[0].toUpperCase()}${sourceProvider.slice(1)}MigrationPreviewRequest`
		)
	},
	{
		// list-indexes 200 is an untagged union: the Algolia compatibility arm and
		// the hosted-engine discovery arm. Pin both so a dropped arm is drift.
		schemaName: 'ListSourceIndexesResponseBody',
		refs: ['AlgoliaSourceListResponse', 'ListSourceIndexesResponse']
	}
];

function componentSchema(schemaName: string): JsonSchema {
	const schema = openApi.components?.schemas?.[schemaName];
	expect(schema, `${schemaName} component schema must exist`).toBeDefined();
	expect(schema?.type, `${schemaName} component schema must be an object`).toBe('object');
	return schema as JsonSchema;
}

function propertySchema(schemaName: string, propertyName: string): JsonSchema {
	const schema = componentSchema(schemaName);
	const property = schema.properties?.[propertyName];
	expect(property, `${schemaName}.${propertyName} property must exist`).toBeDefined();
	return property as JsonSchema;
}

function assertRequired(schemaName: string, propertyName: string, required = false): void {
	const schema = componentSchema(schemaName);
	const requiredFields = schema.required ?? [];
	const assertion = expect(
		requiredFields.includes(propertyName),
		`${schemaName}.${propertyName} required-field drift`
	);
	if (required) {
		assertion.toBe(true);
	} else {
		assertion.toBe(false);
	}
}

function assertPrimitiveKind(
	schemaName: string,
	propertyName: string,
	type: PrimitiveKind,
	required = false
): void {
	const property = propertySchema(schemaName, propertyName);
	const allowedType = required ? property.type === type : schemaTypeIncludes(property, type);
	expect(allowedType, `${schemaName}.${propertyName} primitive type drift`).toBe(true);
}

function assertNullableString(schemaName: string, propertyName: string): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.type, `${schemaName}.${propertyName} nullable string type drift`).toEqual([
		'string',
		'null'
	]);
}

function assertNullablePrimitive(
	schemaName: string,
	propertyName: string,
	type: PrimitiveKind
): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.type, `${schemaName}.${propertyName} nullable primitive type drift`).toEqual([
		type,
		'null'
	]);
}

function assertRefArray(schemaName: string, propertyName: string, refName: string): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.type, `${schemaName}.${propertyName} array type drift`).toBe('array');
	expect(property.items?.$ref, `${schemaName}.${propertyName} array item ref drift`).toBe(
		`#/components/schemas/${refName}`
	);
}

function assertPrimitiveArray(schemaName: string, propertyName: string, type: PrimitiveKind): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.type, `${schemaName}.${propertyName} array type drift`).toBe('array');
	expect(property.items?.type, `${schemaName}.${propertyName} array item type drift`).toBe(type);
}

function assertRef(schemaName: string, propertyName: string, refName: string): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.$ref, `${schemaName}.${propertyName} ref drift`).toBe(
		`#/components/schemas/${refName}`
	);
}

function assertNullableRef(schemaName: string, propertyName: string, refName: string): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.oneOf, `${schemaName}.${propertyName} nullable ref drift`).toEqual([
		{ type: 'null' },
		{ $ref: `#/components/schemas/${refName}` }
	]);
}

function assertEnumSchema(descriptor: EnumSchemaDescriptor): void {
	const schema = openApi.components?.schemas?.[descriptor.schemaName];
	expect(schema, `${descriptor.schemaName} component schema must exist`).toBeDefined();
	expect(schema?.type, `${descriptor.schemaName} enum type drift`).toBe('string');
	expect(schema?.enum, `${descriptor.schemaName} enum values drift`).toEqual(descriptor.values);
}

function assertOneOfSchema(descriptor: OneOfSchemaDescriptor): void {
	const schema = openApi.components?.schemas?.[descriptor.schemaName];
	expect(schema, `${descriptor.schemaName} component schema must exist`).toBeDefined();
	expect(
		schema?.oneOf?.map((arm) => arm.$ref),
		`${descriptor.schemaName} oneOf arms drift`
	).toEqual(descriptor.refs.map((ref) => `#/components/schemas/${ref}`));
}

function assertObjectContainer(schemaName: string, propertyName: string): void {
	const property = propertySchema(schemaName, propertyName);
	const objectLike =
		property.type === 'object' ||
		property.$ref !== undefined ||
		(Array.isArray(property.type) && property.type.includes('object')) ||
		property.oneOf?.some((schema) => schema.$ref !== undefined || schema.type === 'object') ===
			true;
	expect(objectLike, `${schemaName}.${propertyName} object container drift`).toBe(true);
}

function assertMapContainer(schemaName: string, propertyName: string): void {
	const property = propertySchema(schemaName, propertyName);
	expect(property.type, `${schemaName}.${propertyName} map container type drift`).toBe('object');
	expect(
		property.additionalProperties,
		`${schemaName}.${propertyName} map additionalProperties drift`
	).toBeDefined();
}

function responseName(descriptor: ResponseDescriptor): string {
	return `${descriptor.method.toUpperCase()} ${descriptor.path} ${descriptor.status}`;
}

function openApiOperation(
	document: OpenApiDocument,
	descriptor: Pick<ResponseDescriptor, 'path' | 'method'>,
	name: string
): OpenApiOperation {
	const path = document.paths?.[descriptor.path];
	expect(path, `${name} spec has no such path: ${descriptor.path}`).toBeDefined();
	const operation = path?.[descriptor.method];
	expect(operation, `${name} operation must exist`).toBeDefined();
	return operation as OpenApiOperation;
}

function jsonResponseSchema(document: OpenApiDocument, descriptor: ResponseDescriptor): JsonSchema {
	const name = responseName(descriptor);
	const operation = openApiOperation(document, descriptor, name);
	const response = operation?.responses?.[descriptor.status];
	expect(response, `${name} response must exist`).toBeDefined();

	const schema = response?.content?.['application/json']?.schema;
	expect(schema, `${name} application/json schema must exist`).toBeDefined();
	return schema as JsonSchema;
}

function assertJsonObjectRequestRef(descriptor: RequestDescriptor): void {
	const name = `${descriptor.method.toUpperCase()} ${descriptor.path} request`;
	const operation = openApiOperation(openApi, descriptor, name);
	const schema = operation.requestBody?.content?.['application/json']?.schema;
	expect(schema?.$ref, `${name} ref drift`).toBe(`#/components/schemas/${descriptor.ref}`);
}

function assertJsonArrayResponseRef(descriptor: ResponseDescriptor): void {
	const name = responseName(descriptor);
	const schema = jsonResponseSchema(openApi, descriptor);
	expect(schema.type, `${name} response array type drift`).toBe('array');
	expect(schema.items?.$ref, `${name} response array item ref drift`).toBe(
		`#/components/schemas/${descriptor.ref}`
	);
}

function assertJsonObjectResponseRef(descriptor: ResponseDescriptor): void {
	const name = responseName(descriptor);
	const schema = jsonResponseSchema(openApi, descriptor);
	expect(schema.$ref, `${name} response ref drift`).toBe(`#/components/schemas/${descriptor.ref}`);
}

function assertProperty(schemaName: string, descriptor: PropertyDescriptor): void {
	assertRequired(schemaName, descriptor.name, descriptor.required ?? false);

	if (descriptor.kind === 'primitive') {
		assertPrimitiveKind(schemaName, descriptor.name, descriptor.type, descriptor.required ?? false);
		return;
	}
	if (descriptor.kind === 'nullablePrimitive') {
		assertNullablePrimitive(schemaName, descriptor.name, descriptor.type);
		return;
	}
	if (descriptor.kind === 'nullableString') {
		assertNullableString(schemaName, descriptor.name);
		return;
	}
	if (descriptor.kind === 'refArray') {
		assertRefArray(schemaName, descriptor.name, descriptor.ref);
		return;
	}
	if (descriptor.kind === 'primitiveArray') {
		assertPrimitiveArray(schemaName, descriptor.name, descriptor.type);
		return;
	}
	if (descriptor.kind === 'ref') {
		assertRef(schemaName, descriptor.name, descriptor.ref);
		return;
	}
	if (descriptor.kind === 'nullableRef') {
		assertNullableRef(schemaName, descriptor.name, descriptor.ref);
		return;
	}
	if (descriptor.kind === 'object') {
		assertObjectContainer(schemaName, descriptor.name);
		return;
	}
	assertMapContainer(schemaName, descriptor.name);
}

function schemaTypeIncludes(schema: JsonSchema, type: PrimitiveKind): boolean {
	return schema.type === type || (Array.isArray(schema.type) && schema.type.includes(type));
}

describe('OpenAPI response boundary guards', () => {
	// This is the arm that actually fired: `53f9c3f89` renamed the published spec
	// path to the neutral `{source_provider}` form without updating the descriptor
	// below, so the lookup resolved to `undefined` and the suite reported a
	// *schema ref* drift for a path that no longer existed. The message must name
	// the missing path, or the next rename is triaged as a schema problem again.
	it('names a missing object-response path instead of collapsing it into ref drift', () => {
		const descriptor: ResponseDescriptor = {
			path: '/migration/algolia/list-indexes',
			method: 'post',
			status: '200',
			ref: 'AlgoliaSourceListResponse'
		};

		const document: OpenApiDocument = {
			paths: {
				'/migration/{source_provider}/list-indexes': {
					post: {
						responses: {
							200: {
								content: {
									'application/json': {
										schema: { $ref: '#/components/schemas/AlgoliaSourceListResponse' }
									}
								}
							}
						}
					}
				}
			}
		};

		expect(() => jsonResponseSchema(document, descriptor)).toThrowError(
			'spec has no such path: /migration/algolia/list-indexes'
		);
	});

	it('names a missing object-response operation instead of collapsing it into ref drift', () => {
		const descriptor: ResponseDescriptor = {
			path: '/migration/{source_provider}/list-indexes',
			method: 'post',
			status: '200',
			ref: 'AlgoliaSourceListResponse'
		};

		const document: OpenApiDocument = {
			paths: {
				'/migration/{source_provider}/list-indexes': {
					get: {
						responses: {
							200: {
								content: {
									'application/json': {
										schema: { $ref: '#/components/schemas/AlgoliaSourceListResponse' }
									}
								}
							}
						}
					}
				}
			}
		};

		expect(() => jsonResponseSchema(document, descriptor)).toThrowError(
			'POST /migration/{source_provider}/list-indexes 200 operation must exist'
		);
	});

	it('names a missing object-response application/json schema boundary', () => {
		const descriptor: ResponseDescriptor = {
			path: '/migration/{source_provider}/list-indexes',
			method: 'post',
			status: '200',
			ref: 'AlgoliaSourceListResponse'
		};

		const document: OpenApiDocument = {
			paths: {
				'/migration/{source_provider}/list-indexes': {
					post: {
						responses: {
							200: {
								content: {
									'text/plain': {
										schema: { type: 'string' }
									}
								}
							}
						}
					}
				}
			}
		};

		expect(() => jsonResponseSchema(document, descriptor)).toThrowError(
			'POST /migration/{source_provider}/list-indexes 200 application/json schema must exist'
		);
	});
});

describe('OpenAPI frontend type drift guard', () => {
	it.each(schemaDescriptors)('$schemaName matches the frontend API type owner', (descriptor) => {
		for (const property of descriptor.properties) {
			assertProperty(descriptor.schemaName, property);
		}
	});

	it.each(arrayResponseDescriptors)(
		'$method $path $status response returns an array of $ref',
		(descriptor) => {
			assertJsonArrayResponseRef(descriptor);
		}
	);

	it.each(objectRequestDescriptors)('$method $path request accepts a $ref object', (descriptor) => {
		assertJsonObjectRequestRef(descriptor);
	});

	it.each(objectResponseDescriptors)(
		'$method $path $status response returns a $ref object',
		(descriptor) => {
			assertJsonObjectResponseRef(descriptor);
		}
	);

	it.each(enumSchemaDescriptors)('$schemaName matches the frontend enum owner', (descriptor) => {
		assertEnumSchema(descriptor);
	});

	it.each(oneOfSchemaDescriptors)('$schemaName matches the frontend oneOf owner', (descriptor) => {
		assertOneOfSchema(descriptor);
	});
});
