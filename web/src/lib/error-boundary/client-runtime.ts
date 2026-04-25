import { buildBoundaryCopy, createSupportReference, resolveBoundaryScope } from './recovery-copy';

const BROWSER_RUNTIME_STATUS = 500;
const FALLBACK_RUNTIME_MESSAGE = 'Browser runtime failure';

export interface NormalizedBrowserFailure {
	status: number;
	error: {
		message: string;
		supportReference: string;
	};
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null;
}

function readString(value: unknown): string | undefined {
	return typeof value === 'string' && value.trim().length > 0 ? value.trim() : undefined;
}

function stringifyUnknown(value: unknown): string | undefined {
	if (!isRecord(value)) return undefined;

	try {
		return JSON.stringify(value);
	} catch {
		return undefined;
	}
}

function extractReasonMessage(value: unknown): string | undefined {
	if (value instanceof Error) {
		return readString(value.message) ?? readString(value.name);
	}

	const directString = readString(value);
	if (directString) return directString;

	if (isRecord(value)) {
		const message = readString(value.message);
		if (message) return message;
	}

	return stringifyUnknown(value);
}

function extractRawBrowserFailureMessage(input: unknown): string {
	if (!isRecord(input)) return FALLBACK_RUNTIME_MESSAGE;

	if (input.type === 'error') {
		const runtimeError = extractReasonMessage(input.error);
		if (runtimeError) return `Uncaught Error: ${runtimeError}`;

		const eventMessage = readString(input.message);
		if (eventMessage) return `Uncaught Error: ${eventMessage}`;
	}

	if (input.type === 'unhandledrejection') {
		const reasonMessage = extractReasonMessage(input.reason);
		if (reasonMessage) return `Unhandled promise rejection: ${reasonMessage}`;
	}

	return extractReasonMessage(input) ?? FALLBACK_RUNTIME_MESSAGE;
}

function browserRuntimePathname(): string {
	return globalThis.location?.pathname ?? '/';
}

function buildBrowserRuntimeReport(
	failure: NormalizedBrowserFailure
): Record<string, string | number> {
	const pathname = browserRuntimePathname();

	return {
		path: pathname,
		status: failure.status,
		scope: resolveBoundaryScope(pathname),
		event_type: 'browser_runtime',
		support_reference: failure.error.supportReference,
		backend_correlation: 'absent'
	};
}

export function normalizeBrowserRuntimeFailure(input: unknown): NormalizedBrowserFailure {
	const supportReference = createSupportReference();
	const scope = resolveBoundaryScope(browserRuntimePathname());
	const boundaryCopy = buildBoundaryCopy(
		{
			status: BROWSER_RUNTIME_STATUS,
			errorMessage: extractRawBrowserFailureMessage(input),
			scope
		},
		supportReference
	);

	return {
		status: BROWSER_RUNTIME_STATUS,
		error: {
			message: boundaryCopy.description,
			supportReference: boundaryCopy.supportReference
		}
	};
}

export function reportBrowserRuntimeFailure(failure: NormalizedBrowserFailure): void {
	// Fire-and-forget redacted client reports with backend_correlation='absent':
	// browser runtime crashes are not associated with backend request IDs.
	const report = buildBrowserRuntimeReport(failure);
	console.error('browser runtime error reported', report);

	try {
		const request = globalThis.fetch('/browser-errors', {
			method: 'POST',
			headers: {
				'content-type': 'application/json'
			},
			body: JSON.stringify(report),
			credentials: 'omit',
			keepalive: true
		});

		void request.catch(() => undefined);
	} catch {
		// Best-effort only: reporting failures must not break runtime recovery.
	}
}

export function installBrowserRuntimeFailureListeners(
	onFailure: (failure: NormalizedBrowserFailure) => void
): () => void {
	const onError = (event: Event): void => {
		onFailure(normalizeBrowserRuntimeFailure(event));
	};
	const onUnhandledRejection = (event: Event): void => {
		onFailure(normalizeBrowserRuntimeFailure(event));
	};

	globalThis.addEventListener('error', onError);
	globalThis.addEventListener('unhandledrejection', onUnhandledRejection);

	return () => {
		globalThis.removeEventListener('error', onError);
		globalThis.removeEventListener('unhandledrejection', onUnhandledRejection);
	};
}
