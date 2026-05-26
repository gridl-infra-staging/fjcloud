import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import type { IndexChatRequest, IndexChatResponse } from '$lib/api/types';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';
import { errorMessage } from './document-management.server';

type ChatActionArgs = {
	request: Request;
	indexName: string;
	token: string | undefined;
};

const MAX_CHAT_QUERY_LENGTH = 2_000;
const MAX_CHAT_HISTORY_ENTRIES = 100;

function failForChatAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

function failForChatValidation(chatError: string, chatQuery?: string) {
	return fail(400, chatQuery ? { chatError, chatQuery } : { chatError });
}

function parseConversationHistory(rawConversationHistory: string): {
	conversationHistory: Record<string, unknown>[];
	chatError?: string;
} {
	if (!rawConversationHistory) {
		return { conversationHistory: [] };
	}

	let parsedConversationHistory: unknown;
	try {
		parsedConversationHistory = JSON.parse(rawConversationHistory);
	} catch {
		return {
			conversationHistory: [],
			chatError: 'conversationHistory must be valid JSON'
		};
	}

	if (
		!Array.isArray(parsedConversationHistory) ||
		parsedConversationHistory.some(
			(entry) => typeof entry !== 'object' || entry === null || Array.isArray(entry)
		)
	) {
		return {
			conversationHistory: [],
			chatError: 'conversationHistory must be a JSON array'
		};
	}

	if (parsedConversationHistory.length > MAX_CHAT_HISTORY_ENTRIES) {
		return {
			conversationHistory: [],
			chatError: `conversationHistory must contain at most ${MAX_CHAT_HISTORY_ENTRIES} entries`
		};
	}

	return {
		conversationHistory: parsedConversationHistory as Record<string, unknown>[]
	};
}

export async function runChatAction({ request, indexName, token }: ChatActionArgs) {
	const data = await request.formData();
	const query = (data.get('query') as string)?.trim() ?? '';
	if (!query) return failForChatValidation('Query is required');
	if (query.length > MAX_CHAT_QUERY_LENGTH) {
		return failForChatValidation(`Query must be at most ${MAX_CHAT_QUERY_LENGTH} characters`);
	}
	const conversationId = (data.get('conversationId') as string | null)?.trim() ?? '';
	const rawConversationHistory = (data.get('conversationHistory') as string | null)?.trim() ?? '';
	const { conversationHistory, chatError } = parseConversationHistory(rawConversationHistory);
	if (chatError) {
		return failForChatValidation(chatError, query);
	}

	const requestBody: IndexChatRequest = {
		query,
		conversationHistory
	};
	if (conversationId) {
		requestBody.conversationId = conversationId;
	}

	const api = createApiClient(token);
	try {
		const chatResponse: IndexChatResponse = await api.chat(indexName, requestBody);
		return { chatResponse, chatQuery: query };
	} catch (error) {
		return failForChatAction(error, {
			chatError: errorMessage(error, 'Failed to get chat response'),
			chatQuery: query
		});
	}
}
