// Customer-facing API key management types.

export interface ApiKeyListItem {
	id: string;
	name: string;
	description: string | null;
	key_prefix: string;
	scopes: string[];
	indexes: string[];
	restrict_sources: string[];
	expires_at: string | null;
	max_hits_per_query: number | null;
	max_queries_per_ip_per_hour: number | null;
	last_used_at: string | null;
	created_at: string;
}

export interface CreateApiKeyRequest {
	name: string;
	scopes: string[];
	description: string | null;
	indexes: string[];
	restrict_sources: string[];
	expires_at: string | null;
	max_hits_per_query: number | null;
	max_queries_per_ip_per_hour: number | null;
}

export interface CreateApiKeyResponse {
	id: string;
	name: string;
	description: string | null;
	key: string;
	key_prefix: string;
	scopes: string[];
	indexes: string[];
	restrict_sources: string[];
	expires_at: string | null;
	max_hits_per_query: number | null;
	max_queries_per_ip_per_hour: number | null;
	created_at: string;
}
