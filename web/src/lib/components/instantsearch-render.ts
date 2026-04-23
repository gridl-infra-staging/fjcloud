const HTML_ESCAPE_MAP: Record<string, string> = {
	'&': '&amp;',
	'<': '&lt;',
	'>': '&gt;',
	'"': '&quot;',
	"'": '&#39;'
};

export function escapeInstantSearchHtml(value: string): string {
	return value.replace(/[&<>"']/g, (character) => HTML_ESCAPE_MAP[character] ?? character);
}

export function renderInstantSearchHit(hit: Record<string, unknown>): string {
	const objectId = escapeInstantSearchHtml(String(hit.objectID ?? ''));
	const formattedHit = escapeInstantSearchHtml(JSON.stringify(hit, null, 2) ?? '');

	return `<div class="hit-item"><strong>${objectId}</strong><pre>${formattedHit}</pre></div>`;
}
