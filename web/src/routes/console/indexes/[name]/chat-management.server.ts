import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import type { IndexChatRequest, IndexChatResponse } from '$lib/api/types';
import { errorMessage } from './document-management.server';
import { mapDashboardSessionFailure } from '$lib/server/auth-action-errors';

type ChatActionArgs = {
	request: Request;
	indexName: string;
	token?: string;
};

function failForDashboardAction<T extends Record<string, unknown>>(error: unknown, payload: T) {
	const sessionFailure = mapDashboardSessionFailure(error);
	if (sessionFailure) return sessionFailure;
	return fail(400, payload);
}

/**
 * TODO: Document chatAction.
 */
const CHAT_QUERY_MAX_LENGTH = 2000;
const CHAT_CONVERSATION_HISTORY_MAX_ENTRIES = 100;

export async function chatAction({ request, indexName, token }: ChatActionArgs) {
	const data = await request.formData();
	const query = (data.get('query') as string)?.trim() ?? '';
	if (!query) return fail(400, { chatError: 'Query is required' });
	if (query.length > CHAT_QUERY_MAX_LENGTH) {
		return fail(400, {
			chatError: `Query must be at most ${CHAT_QUERY_MAX_LENGTH} characters`,
			chatQuery: query
		});
	}
	const conversationId = (data.get('conversationId') as string | null)?.trim() ?? '';

	const rawConversationHistory = (data.get('conversationHistory') as string | null)?.trim() ?? '';
	let conversationHistory: Record<string, unknown>[] = [];

	if (rawConversationHistory) {
		let parsedConversationHistory: unknown;
		try {
			parsedConversationHistory = JSON.parse(rawConversationHistory);
		} catch {
			return fail(400, {
				chatError: 'conversationHistory must be valid JSON',
				chatQuery: query
			});
		}

		if (
			!Array.isArray(parsedConversationHistory) ||
			parsedConversationHistory.some(
				(entry) => typeof entry !== 'object' || entry === null || Array.isArray(entry)
			)
		) {
			return fail(400, {
				chatError: 'conversationHistory must be a JSON array',
				chatQuery: query
			});
		}

		if (parsedConversationHistory.length > CHAT_CONVERSATION_HISTORY_MAX_ENTRIES) {
			return fail(400, {
				chatError: `conversationHistory must contain at most ${CHAT_CONVERSATION_HISTORY_MAX_ENTRIES} entries`,
				chatQuery: query
			});
		}

		conversationHistory = parsedConversationHistory as Record<string, unknown>[];
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
	} catch (e) {
		return failForDashboardAction(e, {
			chatError: errorMessage(e, 'Failed to get chat response'),
			chatQuery: query
		});
	}
}
