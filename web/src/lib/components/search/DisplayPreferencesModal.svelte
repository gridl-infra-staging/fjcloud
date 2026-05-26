<script lang="ts">
	import {
		loadSearchDisplayPrefs,
		saveSearchDisplayPrefs,
		type SearchDisplayPrefs
	} from './display_prefs_storage';

	let {
		open = false,
		availableAttributes = ['title', 'body'],
		onClose = () => {}
	}: {
		open?: boolean;
		availableAttributes?: string[];
		onClose?: () => void;
	} = $props();

	let hitsPerPageDraft = $state(20);
	let highlightedAttributesDraft = $state<string[]>([]);

	$effect(() => {
		if (!open) {
			return;
		}

		const savedPreferences = loadSearchDisplayPrefs();
		hitsPerPageDraft = savedPreferences.hitsPerPage;
		highlightedAttributesDraft = [...savedPreferences.highlightedAttributes];
	});

	function toggleHighlightedAttribute(attribute: string): void {
		if (highlightedAttributesDraft.includes(attribute)) {
			highlightedAttributesDraft = highlightedAttributesDraft.filter(
				(existingAttribute) => existingAttribute !== attribute
			);
			return;
		}

		highlightedAttributesDraft = [...highlightedAttributesDraft, attribute];
	}

	function savePreferences(): void {
		const preferences: SearchDisplayPrefs = {
			hitsPerPage:
				Number.isFinite(hitsPerPageDraft) && hitsPerPageDraft > 0 ? hitsPerPageDraft : 20,
			highlightedAttributes: highlightedAttributesDraft
		};
		saveSearchDisplayPrefs(preferences);
		onClose();
	}
</script>

{#if open}
	<section
		class="rounded-lg border border-flapjack-ink/20 bg-white p-4"
		data-testid="display-preferences-modal"
	>
		<h3 class="mb-3 text-base font-semibold text-flapjack-ink">Display preferences</h3>

		<label class="mb-3 block text-sm text-flapjack-ink" for="display-preferences-hits-per-page">
			Hits per page
		</label>
		<input
			id="display-preferences-hits-per-page"
			type="number"
			min="1"
			aria-label="Hits per page"
			value={hitsPerPageDraft}
			class="mb-4 w-full rounded-md border border-flapjack-ink/20 px-2 py-1"
			oninput={(event) =>
				(hitsPerPageDraft = Number.parseInt((event.currentTarget as HTMLInputElement).value, 10))}
		/>

		<div class="mb-4 space-y-2">
			{#each availableAttributes as attribute (attribute)}
				<label class="flex items-center gap-2 text-sm text-flapjack-ink">
					<input
						type="checkbox"
						checked={highlightedAttributesDraft.includes(attribute)}
						aria-label={`Highlight ${attribute}`}
						onchange={() => toggleHighlightedAttribute(attribute)}
					/>
					Highlight {attribute}
				</label>
			{/each}
		</div>

		<div class="flex gap-2">
			<button
				type="button"
				class="rounded-md bg-flapjack-rose px-3 py-1 text-sm text-white hover:bg-flapjack-plum"
				onclick={savePreferences}
			>
				Save preferences
			</button>
			<button
				type="button"
				class="rounded-md border border-flapjack-ink/20 px-3 py-1 text-sm"
				onclick={onClose}
			>
				Cancel
			</button>
		</div>
	</section>
{/if}
