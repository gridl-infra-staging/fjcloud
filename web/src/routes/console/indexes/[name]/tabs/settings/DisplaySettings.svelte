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

	const displayedAttributesValue = $derived(formatStringList(draft?.displayedAttributes));

	function setDisplayedAttributes(value: string): void {
		updateSettingsDraft((nextDraft) => {
			nextDraft.displayedAttributes = parseCommaSeparatedList(value);
		});
	}

	function handleDisplayedAttributesInput(event: TextInputEvent): void {
		setDisplayedAttributes(event.currentTarget.value);
	}
</script>

<div>
	<label
		for="settings-displayed-attributes"
		class="mb-1 block text-sm font-medium text-flapjack-ink/80">Displayed Attributes</label
	>
	<input
		id="settings-displayed-attributes"
		type="text"
		value={displayedAttributesValue}
		oninput={handleDisplayedAttributesInput}
		placeholder="title, description, price"
		class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
	/>
</div>
