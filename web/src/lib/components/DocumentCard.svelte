<script lang="ts">
	import DOMPurify from 'dompurify';

	type HighlightValue = {
		value?: unknown;
	};

	type SearchHit = Record<string, unknown> & {
		_highlightResult?: Record<string, HighlightValue | undefined>;
	};

	let { hit }: { hit: SearchHit } = $props();

	function orderedFieldNames(nextHit: SearchHit): string[] {
		const fieldNames = Object.keys(nextHit).filter((fieldName) => fieldName !== '_highlightResult');
		const otherFields = fieldNames
			.filter((fieldName) => fieldName !== 'objectID')
			.sort((left, right) => left.localeCompare(right));

		return fieldNames.includes('objectID') ? ['objectID', ...otherFields] : otherFields;
	}

	function toDisplayString(value: unknown): string {
		if (typeof value === 'string') {
			return value;
		}

		if (typeof value === 'number' || typeof value === 'boolean') {
			return String(value);
		}

		if (value === null || value === undefined) {
			return '';
		}

		return JSON.stringify(value);
	}

	function sanitizedHighlightHtml(nextHit: SearchHit, fieldName: string): string | null {
		const rawHighlight = nextHit._highlightResult?.[fieldName]?.value;
		if (typeof rawHighlight !== 'string' || rawHighlight.length === 0) {
			return null;
		}

		return DOMPurify.sanitize(rawHighlight, {
			FORBID_TAGS: ['img', 'script', 'style', 'iframe', 'object'],
			FORBID_ATTR: ['onerror', 'onload']
		});
	}
</script>

<article class="rounded-lg border border-flapjack-ink/15 bg-white p-4" data-testid="document-card">
	{#each orderedFieldNames(hit) as fieldName (fieldName)}
		{@const highlightHtml = sanitizedHighlightHtml(hit, fieldName)}
		<div class="mb-2" data-testid="document-card-field" data-field-name={fieldName}>
			<div class="text-xs font-semibold uppercase text-flapjack-ink/55">{fieldName}</div>
			{#if highlightHtml}
				<div class="text-sm text-flapjack-ink" data-testid={`document-card-highlight-${fieldName}`}>
					<!-- eslint-disable-next-line svelte/no-at-html-tags -->
					{@html highlightHtml}
				</div>
			{:else}
				<div class="text-sm text-flapjack-ink">{toDisplayString(hit[fieldName])}</div>
			{/if}
		</div>
	{/each}
</article>
