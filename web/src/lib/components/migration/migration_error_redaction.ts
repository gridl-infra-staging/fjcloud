function escapeRegExpLiteral(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function redactErrorMessage(message: string, sensitiveValues: readonly string[]): string {
	let redactedMessage = message;
	for (const value of sensitiveValues) {
		const trimmedValue = value.trim();
		if (trimmedValue === '') {
			continue;
		}
		redactedMessage = redactedMessage.replaceAll(
			new RegExp(escapeRegExpLiteral(trimmedValue), 'g'),
			'[redacted]'
		);
	}
	return redactedMessage;
}

export function toErrorMessage(error: unknown, sensitiveValues: readonly string[] = []): string {
	const message = error instanceof Error ? error.message : String(error);
	return redactErrorMessage(message, sensitiveValues);
}
