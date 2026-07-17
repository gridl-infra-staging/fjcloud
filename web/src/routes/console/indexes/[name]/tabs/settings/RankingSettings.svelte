<script lang="ts">
	import {
		formatStringList,
		getOptionalIntegerString,
		getOptionalString,
		parseCommaSeparatedList,
		parseOptionalInteger,
		type SettingsDraft,
		type SettingsDraftMutator
	} from './settings_draft';

	type Props = {
		draft: SettingsDraft | null;
		updateSettingsDraft: (mutator: SettingsDraftMutator) => void;
	};

	type TextInputEvent = Event & { currentTarget: EventTarget & HTMLInputElement };

	let { draft, updateSettingsDraft }: Props = $props();

	const rankingRulesValue = $derived(formatStringList(draft?.rankingRules));
	const customRankingValue = $derived(formatStringList(draft?.customRanking));
	const distinctAttributeValue = $derived(getOptionalString(draft?.distinctAttribute));
	const distinctLimitValue = $derived(getOptionalIntegerString(draft?.distinctLimit));

	function setStringList(key: 'rankingRules' | 'customRanking', value: string): void {
		updateSettingsDraft((nextDraft) => {
			nextDraft[key] = parseCommaSeparatedList(value);
		});
	}

	function setDistinctAttribute(value: string): void {
		updateSettingsDraft((nextDraft) => {
			const trimmed = value.trim();
			if (trimmed.length > 0) {
				nextDraft.distinctAttribute = trimmed;
				return;
			}

			delete nextDraft.distinctAttribute;
		});
	}

	function setDistinctLimit(value: string): void {
		const parsed = parseOptionalInteger(value);
		updateSettingsDraft((nextDraft) => {
			if (parsed === null) {
				delete nextDraft.distinctLimit;
				return;
			}

			nextDraft.distinctLimit = parsed;
		});
	}

	function handleRankingRulesInput(event: TextInputEvent): void {
		setStringList('rankingRules', event.currentTarget.value);
	}

	function handleCustomRankingInput(event: TextInputEvent): void {
		setStringList('customRanking', event.currentTarget.value);
	}

	function handleDistinctAttributeInput(event: TextInputEvent): void {
		setDistinctAttribute(event.currentTarget.value);
	}

	function handleDistinctLimitInput(event: TextInputEvent): void {
		setDistinctLimit(event.currentTarget.value);
	}
</script>

<div class="grid grid-cols-1 gap-4 md:grid-cols-2">
	<div>
		<label for="settings-ranking-rules" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>Ranking Rules</label
		>
		<input
			id="settings-ranking-rules"
			type="text"
			value={rankingRulesValue}
			oninput={handleRankingRulesInput}
			placeholder="words, typo, proximity"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>

	<div>
		<label for="settings-custom-ranking" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>Custom Ranking</label
		>
		<input
			id="settings-custom-ranking"
			type="text"
			value={customRankingValue}
			oninput={handleCustomRankingInput}
			placeholder="desc(popularity), asc(price)"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>

	<div>
		<label
			for="settings-distinct-attribute"
			class="mb-1 block text-sm font-medium text-flapjack-ink/80">Distinct Attribute</label
		>
		<input
			id="settings-distinct-attribute"
			type="text"
			value={distinctAttributeValue}
			oninput={handleDistinctAttributeInput}
			placeholder="sku"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>

	<div>
		<label for="settings-distinct-limit" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>Distinct Limit</label
		>
		<input
			id="settings-distinct-limit"
			type="number"
			value={distinctLimitValue}
			oninput={handleDistinctLimitInput}
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>
</div>
