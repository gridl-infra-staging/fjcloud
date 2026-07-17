// Event debugger types (Stage 8).

export interface DebugEvent {
	timestampMs: number;
	index: string;
	eventType: string;
	eventSubtype: string | null;
	eventName: string;
	userToken: string;
	objectIds: string[];
	httpCode: number;
	validationErrors: string[];
}

export interface DebugEventsResponse {
	events: DebugEvent[];
	count: number;
}

export interface DebugEventsFilters {
	eventType?: string;
	status?: string;
	limit?: number;
	from?: number;
	until?: number;
}
