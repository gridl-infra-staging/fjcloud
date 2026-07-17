export function escapeForRegex(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function exactTextMatcher(value: string): RegExp {
	return new RegExp(`^${escapeForRegex(value)}$`);
}
