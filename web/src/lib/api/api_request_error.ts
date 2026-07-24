export class ApiRequestError extends Error {
	constructor(
		public readonly status: number,
		message: string,
		public readonly metadata: { requestId?: string; headers?: Headers; body?: unknown } = {}
	) {
		super(message);
		this.name = 'ApiRequestError';
	}

	get requestId(): string | undefined {
		return this.metadata.requestId;
	}

	get headers(): Headers | undefined {
		return this.metadata.headers;
	}

	get body(): unknown {
		return this.metadata.body;
	}
}
