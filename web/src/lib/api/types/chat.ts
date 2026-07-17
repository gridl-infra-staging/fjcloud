// Per-index conversational chat request and response types.

export interface IndexChatRequest {
	query: string;
	model?: string;
	conversationHistory?: Record<string, unknown>[];
	conversationId?: string;
}

export interface IndexChatResponse {
	answer: string;
	sources: Record<string, unknown>[];
	conversationId: string;
	queryID: string;
}
