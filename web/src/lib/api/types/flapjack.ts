// Flapjack VM-side API key types — returned by POST /indexes/:name/keys.
// Matches Rust FlapjackApiKey with #[serde(rename_all = "camelCase")].
// Different from FlapjackCredentials (returned by POST /onboarding/credentials).

export interface CreateIndexKeyRequest {
	description: string;
	acl: string[];
}

export interface FlapjackApiKey {
	key: string;
	createdAt: string;
}
