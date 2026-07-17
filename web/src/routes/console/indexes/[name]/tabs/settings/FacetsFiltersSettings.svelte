<script lang="ts">
	import {
		formatStringList,
		parseCommaSeparatedList,
		type SettingsDraft,
		type SettingsDraftMutator
	} from './settings_draft';

	type Props = {
		draft: SettingsDraft | null;
		updateSettingsDraft: (mutator: SettingsDraftMutator) => void;
	};

	type TextInputEvent = Event & { currentTarget: EventTarget & HTMLInputElement };

	let { draft, updateSettingsDraft }: Props = $props();

	const filterableAttributesValue = $derived(formatStringList(draft?.filterableAttributes));
	const filterableAttributeEntries = $derived(
		Array.isArray(draft?.filterableAttributes)
			? draft.filterableAttributes.filter((item): item is string => typeof item === 'string')
			: []
	);

	function setFilterableAttributes(value: string): void {
		updateSettingsDraft((nextDraft) => {
			nextDraft.filterableAttributes = parseCommaSeparatedList(value);
		});
	}

	function handleFilterableAttributesInput(event: TextInputEvent): void {
		setFilterableAttributes(event.currentTarget.value);
	}

	function isFilterOnlyAttribute(value: string): boolean {
		return value.startsWith('filterOnly(') && value.endsWith(')');
	}
</script>

<div class="space-y-4">
	<div>
		<label
			for="settings-filterable-attributes"
			class="mb-1 block text-sm font-medium text-flapjack-ink/80">Filterable Attributes</label
		>
		<input
			id="settings-filterable-attributes"
			type="text"
			value={filterableAttributesValue}
			oninput={handleFilterableAttributesInput}
			placeholder="category, filterOnly(brand), price"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>

	{#if filterableAttributeEntries.length > 0}
		<ul class="flex flex-wrap gap-2" aria-label="Filterable attribute preview">
			{#each filterableAttributeEntries as attribute, index (`${index}:${attribute}`)}
				<li
					class="rounded-md border border-flapjack-ink/20 bg-white px-2 py-1 text-xs text-flapjack-ink/80"
				>
					<span>{attribute}</span>
					{#if isFilterOnlyAttribute(attribute)}
						<span class="ml-2 rounded-sm bg-flapjack-cream px-1.5 py-0.5 text-flapjack-plum">
							Filter-only facet
						</span>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</div>
