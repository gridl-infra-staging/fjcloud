// Envelope response types shared across many API endpoints.

export interface MessageResponse {
	message: string;
}

export interface MessageWithRetryAfterResponse {
	message: string;
	retryAfterSeconds: number | null;
}

export interface ApiError {
	error: string;
	status: number;
}
