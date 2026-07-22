import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

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

type PropertyDescriptor =
	| {
			name: string;
			kind: 'primitive';
			type: PrimitiveKind;
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'nullableString';
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'refArray';
			ref: string;
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'primitiveArray';
			type: PrimitiveKind;
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'ref';
			ref: string;
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'nullableRef';
			ref: string;
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'object';
			required?: boolean;
	  }
	| {
			name: string;
			kind: 'map';
			required?: boolean;
	  };

type SchemaDescriptor = {
	schemaName: string;
	properties: PropertyDescriptor[];
};

type ArrayResponseDescriptor = {
	path: string;
	method: 'get' | 'post';
	status: string;
	ref: string;
};

type ObjectResponseDescriptor = {
	path: string;
	method: 'get' | 'post';
	status: string;
	ref: string;
};

type EnumSchemaDescriptor = {
	schemaName: string;
	values: string[];
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
			{ name: 'reason', kind: 'ref', ref: 'AlgoliaMigrationAvailabilityReason', required: true },
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
	}
];

const arrayResponseDescriptors: ArrayResponseDescriptor[] = [
	{ path: '/indexes', method: 'get', status: '200', ref: 'IndexResponse' }
];

const objectResponseDescriptors: ObjectResponseDescriptor[] = [
	{
		path: '/migration/algolia/list-indexes',
		method: 'post',
		status: '200',
		ref: 'AlgoliaSourceListResponse'
	},
	{
		path: '/indexes/{name}/infrastructure',
		method: 'get',
		status: '200',
		ref: 'IndexInfrastructureResponse'
	}
];

const enumSchemaDescriptors: EnumSchemaDescriptor[] = [
	{ schemaName: 'HeadroomStatus', values: ['comfortable', 'busy', 'approaching_limits'] },
	{ schemaName: 'UtilizationBucket', values: ['green', 'yellow', 'red'] }
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

function assertJsonArrayResponseRef(descriptor: ArrayResponseDescriptor): void {
	const responseName = `${descriptor.method.toUpperCase()} ${descriptor.path} ${descriptor.status}`;
	const operation = openApi.paths?.[descriptor.path]?.[descriptor.method];
	expect(operation, `${responseName} operation must exist`).toBeDefined();

	const response = operation?.responses?.[descriptor.status];
	expect(response, `${responseName} response must exist`).toBeDefined();

	const schema = response?.content?.['application/json']?.schema;
	expect(schema, `${responseName} application/json schema must exist`).toBeDefined();
	expect(schema?.type, `${responseName} response array type drift`).toBe('array');
	expect(schema?.items?.$ref, `${responseName} response array item ref drift`).toBe(
		`#/components/schemas/${descriptor.ref}`
	);
}

function assertJsonObjectResponseRef(descriptor: ObjectResponseDescriptor): void {
	const responseName = `${descriptor.method.toUpperCase()} ${descriptor.path} ${descriptor.status}`;
	const schema =
		openApi.paths?.[descriptor.path]?.[descriptor.method]?.responses?.[descriptor.status]
			?.content?.['application/json']?.schema;
	expect(schema?.$ref, `${responseName} response ref drift`).toBe(
		`#/components/schemas/${descriptor.ref}`
	);
}

function assertProperty(schemaName: string, descriptor: PropertyDescriptor): void {
	assertRequired(schemaName, descriptor.name, descriptor.required ?? false);

	if (descriptor.kind === 'primitive') {
		assertPrimitiveKind(schemaName, descriptor.name, descriptor.type, descriptor.required ?? false);
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

	it.each(objectResponseDescriptors)(
		'$method $path $status response returns a $ref object',
		(descriptor) => {
			assertJsonObjectResponseRef(descriptor);
		}
	);

	it.each(enumSchemaDescriptors)('$schemaName matches the frontend enum owner', (descriptor) => {
		assertEnumSchema(descriptor);
	});
});
