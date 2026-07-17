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

	type SelectChangeEvent = Event & { currentTarget: EventTarget & HTMLSelectElement };
	type TextInputEvent = Event & { currentTarget: EventTarget & HTMLInputElement };

	let { draft, updateSettingsDraft }: Props = $props();

	const modeValue = $derived(
		typeof draft?.mode === 'string' && draft.mode.length > 0 ? draft.mode : 'standard'
	);
	const searchableAttributesValue = $derived(formatStringList(draft?.searchableAttributes));

	function setMode(mode: string): void {
		updateSettingsDraft((nextDraft) => {
			nextDraft.mode = mode;
		});
	}

	function setSearchableAttributes(value: string): void {
		updateSettingsDraft((nextDraft) => {
			nextDraft.searchableAttributes = parseCommaSeparatedList(value);
		});
	}

	function handleModeChange(event: SelectChangeEvent): void {
		setMode(event.currentTarget.value);
	}

	function handleSearchableAttributesInput(event: TextInputEvent): void {
		setSearchableAttributes(event.currentTarget.value);
	}
</script>

<div class="grid grid-cols-1 gap-4 md:grid-cols-2">
	<div>
		<label for="settings-mode" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>Mode</label
		>
		<select
			id="settings-mode"
			value={modeValue}
			onchange={handleModeChange}
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		>
			<option value="standard">standard</option>
			<option value="neuralSearch">neuralSearch</option>
		</select>
	</div>

	<div>
		<label
			for="settings-searchable-attributes"
			class="mb-1 block text-sm font-medium text-flapjack-ink/80">Searchable Attributes</label
		>
		<input
			id="settings-searchable-attributes"
			type="text"
			value={searchableAttributesValue}
			oninput={handleSearchableAttributesInput}
			placeholder="title, sku, brand"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>
</div>
