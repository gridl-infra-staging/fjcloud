import type { VerifySourceMigrationResponse } from '$lib/api/types';
import { toErrorMessage } from './migration_error_redaction';

export interface MigrationCutoverVerificationError {
	code: string | null;
	message: string;
}

export interface MigrationCutoverVerificationInputs {
	queries: string[];
	resultLimit: number;
}

export interface MigrationCutoverVerificationIntent extends MigrationCutoverVerificationInputs {
	appId: string;
	apiKey: string;
}

export interface MigrationCutoverVerificationState {
	result: VerifySourceMigrationResponse | null;
	binding: string | null;
	attemptBinding: string | null;
	error: MigrationCutoverVerificationError | null;
	activeRequest: boolean;
}

export type MigrationCutoverVerificationActionResult =
	| { report: VerifySourceMigrationResponse; error?: never }
	| { report?: never; error: { code?: string | null; message?: string | null } }
	| { report?: never; error?: never; actionApplied: true };

interface PreparedMigrationCutoverVerification {
	binding: string;
	redactions: string[];
	submit: () => Promise<MigrationCutoverVerificationActionResult>;
}

interface RequestMigrationCutoverVerificationOptions {
	prepare: () => PreparedMigrationCutoverVerification | null;
	currentBinding: () => string | null;
}

export function createMigrationCutoverVerificationState(): MigrationCutoverVerificationState {
	return {
		result: null,
		binding: null,
		attemptBinding: null,
		error: null,
		activeRequest: false
	};
}

export function clearMigrationCutoverVerificationState(
	state: MigrationCutoverVerificationState
): void {
	state.result = null;
	state.binding = null;
	state.attemptBinding = null;
	state.error = null;
}

export async function requestMigrationCutoverVerification(
	state: MigrationCutoverVerificationState,
	options: RequestMigrationCutoverVerificationOptions
): Promise<void> {
	if (state.activeRequest) return;
	const preparationBinding = options.currentBinding();
	state.activeRequest = true;
	clearMigrationCutoverVerificationState(state);
	let prepared: PreparedMigrationCutoverVerification | null = null;
	try {
		prepared = options.prepare();
		if (prepared === null) return;
		const result = await prepared.submit();
		if (options.currentBinding() !== prepared.binding) return;
		if ('actionApplied' in result) return;
		state.attemptBinding = prepared.binding;
		if ('report' in result && result.report !== undefined) {
			state.result = result.report;
			state.binding = prepared.binding;
			return;
		}
		state.error = sanitizedVerificationError(result.error, prepared.redactions);
	} catch (error) {
		if (prepared !== null && options.currentBinding() !== prepared.binding) return;
		const attemptBinding = prepared?.binding ?? preparationBinding;
		if (attemptBinding === null) return;
		state.attemptBinding = attemptBinding;
		state.error = {
			code: null,
			message: toErrorMessage(error, prepared?.redactions ?? [])
		};
	} finally {
		state.activeRequest = false;
	}
}

function sanitizedVerificationError(
	error: { code?: string | null; message?: string | null },
	redactions: readonly string[]
): MigrationCutoverVerificationError {
	return {
		code: typeof error.code === 'string' && error.code.trim() !== '' ? error.code : null,
		message: toErrorMessage(
			error.message ?? error.code ?? 'Cutover verification failed',
			redactions
		)
	};
}
