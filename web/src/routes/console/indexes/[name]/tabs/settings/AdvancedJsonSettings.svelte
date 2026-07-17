<script lang="ts">
	import {
		createDefaultEmbedders,
		createDefaultHybridSettings,
		getEmbedderDraftEntry,
		getEmbedderEntries,
		isRecord,
		parseOptionalInteger,
		updateHybridDraft,
		type SettingsDraft,
		type SettingsDraftMutator
	} from './settings_draft';

	type Props = {
		draft: SettingsDraft | null;
		updateSettingsDraft: (mutator: SettingsDraftMutator) => void;
	};

	type CheckboxChangeEvent = Event & { currentTarget: EventTarget & HTMLInputElement };
	type TextInputEvent = Event & { currentTarget: EventTarget & HTMLInputElement };

	let { draft, updateSettingsDraft }: Props = $props();

	const embeddersEnabled = $derived(isRecord(draft?.embedders));
	const hybridSettings = $derived(isRecord(draft?.hybrid) ? draft.hybrid : null);
	const hybridEnabled = $derived(hybridSettings !== null);
	const reRankingEnabled = $derived(draft?.enableReRanking === true);
	const reRankingApplyFilterValue = $derived(
		typeof draft?.reRankingApplyFilter === 'string' ? draft.reRankingApplyFilter : ''
	);
	const semanticRatioValue = $derived(
		hybridSettings && typeof hybridSettings.semanticRatio === 'number'
			? hybridSettings.semanticRatio
			: 0.5
	);
	const hybridEmbedderValue = $derived(
		hybridSettings && typeof hybridSettings.embedder === 'string'
			? hybridSettings.embedder
			: 'default'
	);
	const embedderEntries = $derived(getEmbedderEntries(draft?.embedders));
	const hybridEmbedderOptions = $derived.by(() => {
		const names = embedderEntries.map(([name]) => name);
		return names.includes(hybridEmbedderValue) ? names : [...names, hybridEmbedderValue];
	});

	function setEmbeddersEnabled(enabled: boolean): void {
		updateSettingsDraft((nextDraft) => {
			if (enabled) {
				nextDraft.embedders = isRecord(nextDraft.embedders)
					? nextDraft.embedders
					: createDefaultEmbedders();
				return;
			}

			delete nextDraft.embedders;
			delete nextDraft.hybrid;
		});
	}

	function setHybridEnabled(enabled: boolean): void {
		updateSettingsDraft((nextDraft) => {
			if (enabled) {
				nextDraft.hybrid = isRecord(nextDraft.hybrid)
					? nextDraft.hybrid
					: createDefaultHybridSettings(nextDraft);
				return;
			}

			delete nextDraft.hybrid;
		});
	}

	function setHybridSemanticRatio(value: string): void {
		const semanticRatio = Number.parseFloat(value);
		updateSettingsDraft((nextDraft) => {
			updateHybridDraft(nextDraft, (hybrid) => {
				hybrid.semanticRatio = semanticRatio;
			});
		});
	}

	function setHybridEmbedder(embedder: string): void {
		updateSettingsDraft((nextDraft) => {
			updateHybridDraft(nextDraft, (hybrid) => {
				hybrid.embedder = embedder;
			});
		});
	}

	function setReRankingEnabled(enabled: boolean): void {
		updateSettingsDraft((nextDraft) => {
			nextDraft.enableReRanking = enabled;
		});
	}

	function setReRankingApplyFilter(filterValue: string): void {
		updateSettingsDraft((nextDraft) => {
			const filter = filterValue.trim();
			if (filter.length > 0) {
				nextDraft.reRankingApplyFilter = filter;
				return;
			}

			delete nextDraft.reRankingApplyFilter;
		});
	}

	function setEmbedderSource(name: string, source: string): void {
		updateSettingsDraft((nextDraft) => {
			const entry = getEmbedderDraftEntry(nextDraft, name);
			if (entry) entry.source = source;
		});
	}

	function setEmbedderDimensions(name: string, value: string): void {
		const nextDimensions = parseOptionalInteger(value);
		updateSettingsDraft((nextDraft) => {
			const entry = getEmbedderDraftEntry(nextDraft, name);
			if (!entry) return;
			if (nextDimensions === null) {
				delete entry.dimensions;
				return;
			}

			entry.dimensions = nextDimensions;
		});
	}

	function handleEmbeddersToggle(event: CheckboxChangeEvent): void {
		setEmbeddersEnabled(event.currentTarget.checked);
	}

	function handleHybridToggle(event: CheckboxChangeEvent): void {
		setHybridEnabled(event.currentTarget.checked);
	}

	function handleReRankingToggle(event: CheckboxChangeEvent): void {
		setReRankingEnabled(event.currentTarget.checked);
	}

	function handleReRankingApplyFilterInput(event: TextInputEvent): void {
		setReRankingApplyFilter(event.currentTarget.value);
	}
</script>

<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Vector, Hybrid, and Re-ranking</h3>
<p class="mb-4 text-sm text-flapjack-ink/70">
	These controls update the same Settings JSON draft below before save.
</p>

<div class="flex flex-col gap-3">
	<label class="inline-flex items-center gap-2 text-sm text-flapjack-ink/80">
		<input type="checkbox" checked={embeddersEnabled} onchange={handleEmbeddersToggle} />
		<span>Enable Embedders</span>
	</label>

	<label class="inline-flex items-center gap-2 text-sm text-flapjack-ink/80">
		<input type="checkbox" checked={hybridEnabled} onchange={handleHybridToggle} />
		<span>Enable Hybrid Search</span>
	</label>

	{#if hybridEnabled}
		<div class="ml-6 grid grid-cols-1 gap-3 md:grid-cols-2">
			<div>
				<label for="settings-semantic-ratio" class="mb-1 block text-sm text-flapjack-ink/80"
					>Semantic Ratio</label
				>
				<input
					id="settings-semantic-ratio"
					type="range"
					min="0"
					max="1"
					step="0.1"
					value={semanticRatioValue}
					oninput={(event) =>
						setHybridSemanticRatio((event.currentTarget as HTMLInputElement).value)}
					class="w-full"
				/>
				<span class="text-xs text-flapjack-ink/60">{semanticRatioValue}</span>
			</div>
			<div>
				<label for="settings-hybrid-embedder" class="mb-1 block text-sm text-flapjack-ink/80"
					>Hybrid Embedder</label
				>
				<select
					id="settings-hybrid-embedder"
					value={hybridEmbedderValue}
					onchange={(event) => setHybridEmbedder((event.currentTarget as HTMLSelectElement).value)}
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				>
					{#each hybridEmbedderOptions as name (name)}
						<option value={name}>{name}</option>
					{/each}
				</select>
			</div>
		</div>
	{/if}

	<label class="inline-flex items-center gap-2 text-sm text-flapjack-ink/80">
		<input type="checkbox" checked={reRankingEnabled} onchange={handleReRankingToggle} />
		<span>Enable Re-ranking</span>
	</label>

	<div>
		<label for="settings-reranking-filter" class="mb-1 block text-sm text-flapjack-ink/80">
			Re-ranking Apply Filter
		</label>
		<input
			id="settings-reranking-filter"
			type="text"
			value={reRankingApplyFilterValue}
			oninput={handleReRankingApplyFilterInput}
			placeholder="brand:Nike"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
	</div>
</div>

{#if embeddersEnabled && embedderEntries.length > 0}
	<div class="mt-6">
		<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Embedder Configuration</h3>
		{#each embedderEntries as [name, config] (name)}
			<div class="mb-3 rounded-md border border-flapjack-ink/10 p-3">
				<span class="mb-2 block text-sm font-medium text-flapjack-ink">{name}</span>
				<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
					<div>
						<label for="embedder-{name}-source" class="mb-1 block text-sm text-flapjack-ink/80"
							>{name} source</label
						>
						<select
							id="embedder-{name}-source"
							value={typeof config.source === 'string' ? config.source : ''}
							onchange={(event) =>
								setEmbedderSource(name, (event.currentTarget as HTMLSelectElement).value)}
							class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						>
							<option value="userProvided">userProvided</option>
							<option value="openAi">openAi</option>
							<option value="huggingFace">huggingFace</option>
							<option value="ollama">ollama</option>
							<option value="rest">rest</option>
						</select>
					</div>
					<div>
						<label for="embedder-{name}-dimensions" class="mb-1 block text-sm text-flapjack-ink/80"
							>{name} dimensions</label
						>
						<input
							id="embedder-{name}-dimensions"
							type="number"
							value={typeof config.dimensions === 'number' ? config.dimensions : ''}
							oninput={(event) =>
								setEmbedderDimensions(name, (event.currentTarget as HTMLInputElement).value)}
							class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						/>
					</div>
				</div>
			</div>
		{/each}
	</div>
{/if}
