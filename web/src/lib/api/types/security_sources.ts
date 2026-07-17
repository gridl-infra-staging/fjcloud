// Security-sources catalog exposed to the customer console.

export interface SecuritySource {
	source: string;
	description: string;
}

export interface SecuritySourcesResponse {
	sources: SecuritySource[];
}
