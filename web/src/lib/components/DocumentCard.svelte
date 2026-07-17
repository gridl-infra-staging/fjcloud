<script lang="ts">
	import DOMPurify from 'dompurify';

	type HighlightValue = {
		value?: unknown;
	};

	type SearchHit = Record<string, unknown> & {
		_highlightResult?: Record<string, HighlightValue | HighlightValue[] | undefined>;
	};

	let {
		hit,
		titleField = null,
		subtitleField = null,
		imageField = null,
		tagsField = null,
		showJsonView = false,
		merchMode = false,
		pinnedAt = null,
		onOpenDetails = () => {},
		onPin = () => {},
		onPromote = () => {},
		onBury = () => {}
	}: {
		hit: SearchHit;
		titleField?: string | null;
		subtitleField?: string | null;
		imageField?: string | null;
		tagsField?: string | null;
		showJsonView?: boolean;
		merchMode?: boolean;
		pinnedAt?: number | null;
		onOpenDetails?: () => void;
		onPin?: (objectID: string, position: number) => void;
		onPromote?: (objectID: string) => void;
		onBury?: (objectID: string) => void;
	} = $props();

	let jsonViewOverride = $state<boolean | null>(null);
	let pinPosition = $state(1);

	const slotFields = $derived(
		[titleField, subtitleField, imageField, tagsField].filter(
			(field): field is string => typeof field === 'string' && field.length > 0
		)
	);
	const jsonViewVisible = $derived(jsonViewOverride ?? showJsonView);

	function orderedFieldNames(nextHit: SearchHit, reserved: string[]): string[] {
		const reservedSet = new Set(reserved);
		const fieldNames = Object.keys(nextHit).filter(
			(fieldName) => fieldName !== '_highlightResult' && !reservedSet.has(fieldName)
		);
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
		const highlight = nextHit._highlightResult?.[fieldName];
		const rawHighlight = Array.isArray(highlight) ? undefined : highlight?.value;
		if (typeof rawHighlight !== 'string' || rawHighlight.length === 0) {
			return null;
		}

		return normalizeHighlightMarkup(
			DOMPurify.sanitize(rawHighlight, {
				FORBID_TAGS: ['img', 'script', 'style', 'iframe', 'object'],
				FORBID_ATTR: ['onerror', 'onload']
			})
		);
	}

	function normalizeHighlightMarkup(sanitizedHtml: string): string {
		// The engine chooses emphasis tags, but the application owns highlight semantics
		// and presentation. Sanitizing first ensures this rewrite never promotes unsafe markup.
		return sanitizedHtml
			.replace(
				/<(?:em|mark)(?:\s[^>]*)?>/gi,
				'<mark data-testid="search-highlight" class="search-highlight bg-flapjack-yellow font-bold not-italic">'
			)
			.replace(/<\/(?:em|mark)>/gi, '</mark>');
	}

	function sanitizedHighlightHtmlValues(nextHit: SearchHit, fieldName: string): string[] {
		const highlight = nextHit._highlightResult?.[fieldName];
		const highlightValues = Array.isArray(highlight) ? highlight : highlight ? [highlight] : [];
		return highlightValues
			.map((entry) => {
				if (typeof entry.value !== 'string' || entry.value.length === 0) {
					return null;
				}
				return normalizeHighlightMarkup(
					DOMPurify.sanitize(entry.value, {
						FORBID_TAGS: ['img', 'script', 'style', 'iframe', 'object'],
						FORBID_ATTR: ['onerror', 'onload']
					})
				);
			})
			.filter((entry): entry is string => Boolean(entry));
	}

	function sanitizedImageUrl(value: unknown): string | null {
		if (typeof value !== 'string' || value.length === 0) {
			return null;
		}
		// Only allow http(s) and protocol-relative URLs as image sources.
		if (!/^(https?:)?\/\//.test(value)) {
			return null;
		}
		return value;
	}

	function tagValues(value: unknown): string[] {
		if (Array.isArray(value)) {
			return value.map((entry) => toDisplayString(entry)).filter((entry) => entry.length > 0);
		}
		const single = toDisplayString(value);
		return single.length > 0 ? [single] : [];
	}

	function tagSlotValues(
		nextHit: SearchHit,
		fieldName: string
	): { html: string; highlighted: boolean }[] {
		const highlightHtmlValues = sanitizedHighlightHtmlValues(nextHit, fieldName);
		if (highlightHtmlValues.length > 0) {
			return highlightHtmlValues.map((html) => ({ html, highlighted: true }));
		}

		return tagValues(slotValue(nextHit, fieldName)).map((tag) => ({
			html: tag,
			highlighted: false
		}));
	}

	function toggleJsonView(event: MouseEvent): void {
		event.stopPropagation();
		if (!jsonViewVisible) {
			onOpenDetails();
		}
		jsonViewOverride = !jsonViewVisible;
	}

	function slotValue(nextHit: SearchHit, field: string | null): unknown {
		if (!field) {
			return undefined;
		}
		return nextHit[field];
	}
</script>

<article class="rounded-lg border border-flapjack-ink/15 bg-white p-4" data-testid="document-card">
	<div class="flex items-start gap-4" data-testid="document-card-layout">
		{#if imageField}
			{@const imageUrl = sanitizedImageUrl(slotValue(hit, imageField))}
			{#if imageUrl}
				<img
					class="h-28 w-20 shrink-0 rounded object-cover sm:h-32 sm:w-24"
					src={imageUrl}
					alt=""
					data-testid="document-card-image"
				/>
			{/if}
		{/if}
		<div class="min-w-0 flex-1" data-testid="document-card-content">
			{#if titleField}
				{@const titleValue = slotValue(hit, titleField)}
				{#if titleValue !== undefined && titleValue !== null && titleValue !== ''}
					{@const titleHighlight = sanitizedHighlightHtml(hit, titleField)}
					<div
						class="mb-1 text-base font-semibold text-flapjack-ink"
						data-testid="document-card-title"
					>
						{#if titleHighlight}
							<!-- eslint-disable-next-line svelte/no-at-html-tags -->
							{@html titleHighlight}
						{:else}
							{toDisplayString(titleValue)}
						{/if}
					</div>
				{/if}
			{/if}

			{#if subtitleField}
				{@const subtitleValue = slotValue(hit, subtitleField)}
				{#if subtitleValue !== undefined && subtitleValue !== null && subtitleValue !== ''}
					{@const subtitleHighlight = sanitizedHighlightHtml(hit, subtitleField)}
					<div class="mb-2 text-sm text-flapjack-ink/70" data-testid="document-card-subtitle">
						{#if subtitleHighlight}
							<!-- eslint-disable-next-line svelte/no-at-html-tags -->
							{@html subtitleHighlight}
						{:else}
							{toDisplayString(subtitleValue)}
						{/if}
					</div>
				{/if}
			{/if}

			{#if tagsField}
				{@const tags = tagSlotValues(hit, tagsField)}
				{#if tags.length > 0}
					<div class="mb-2 flex flex-wrap gap-1">
						{#each tags as tag (tag.html)}
							<span
								class="rounded bg-flapjack-cream px-2 py-0.5 text-xs text-flapjack-ink"
								data-testid="document-card-tag"
							>
								{#if tag.highlighted}
									<!-- eslint-disable-next-line svelte/no-at-html-tags -->
									{@html tag.html}
								{:else}
									{tag.html}
								{/if}
							</span>
						{/each}
					</div>
				{/if}
			{/if}

			{#if pinnedAt != null && pinnedAt >= 1}
				<span
					data-testid="card-pinned-badge"
					class="mb-2 inline-block rounded bg-flapjack-cream px-2 py-0.5 text-xs font-semibold text-flapjack-ink"
					>Pinned #{pinnedAt}</span
				>
			{/if}

			{#each orderedFieldNames(hit, slotFields) as fieldName (fieldName)}
				{@const highlightHtml = sanitizedHighlightHtml(hit, fieldName)}
				<div class="mb-2" data-testid="document-card-field" data-field-name={fieldName}>
					<div class="text-xs font-semibold uppercase text-flapjack-ink/55">{fieldName}</div>
					{#if highlightHtml}
						<div
							class="text-sm text-flapjack-ink"
							data-testid={`document-card-highlight-${fieldName}`}
						>
							<!-- eslint-disable-next-line svelte/no-at-html-tags -->
							{@html highlightHtml}
						</div>
					{:else}
						<div class="text-sm text-flapjack-ink">{toDisplayString(hit[fieldName])}</div>
					{/if}
				</div>
			{/each}

			{#if merchMode}
				<div class="mt-2 flex items-center gap-2">
					<input
						type="number"
						min="1"
						aria-label="Pin position"
						data-testid="card-merch-pin-position"
						bind:value={pinPosition}
						class="w-16 rounded border border-flapjack-ink/20 px-2 py-1 text-xs"
					/>
					<button
						type="button"
						data-testid="card-merch-pin"
						class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs text-flapjack-ink hover:bg-flapjack-cream"
						onclick={() => onPin(String(hit.objectID), pinPosition)}>Pin</button
					>
					<button
						type="button"
						data-testid="card-merch-promote"
						class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs text-flapjack-ink hover:bg-flapjack-cream"
						onclick={() => onPromote(String(hit.objectID))}>Promote</button
					>
					<button
						type="button"
						data-testid="card-merch-bury"
						class="rounded border border-flapjack-ink/20 px-2 py-1 text-xs text-flapjack-ink hover:bg-flapjack-cream"
						onclick={() => onBury(String(hit.objectID))}>Bury</button
					>
				</div>
			{/if}

			<button
				type="button"
				class="mt-2 rounded border border-flapjack-ink/20 px-2 py-1 text-xs text-flapjack-ink hover:bg-flapjack-cream"
				onclick={toggleJsonView}
			>
				{jsonViewVisible ? 'Close details' : 'Open details'}
			</button>

			{#if jsonViewVisible}
				<pre
					class="mt-2 overflow-auto rounded bg-flapjack-cream p-2 text-xs text-flapjack-ink"
					data-testid="document-card-json">{JSON.stringify(hit, null, 2)}</pre>
			{/if}
		</div>
	</div>
</article>
