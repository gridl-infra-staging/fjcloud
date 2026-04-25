<script lang="ts">
	import { enhance } from '$app/forms';

	type Props = {
		settings: Record<string, unknown> | null;
		settingsError: string;
		settingsSaved: boolean;
	};

	type CheckboxChangeEvent = Event & { currentTarget: EventTarget & HTMLInputElement };
	type SelectChangeEvent = Event & { currentTarget: EventTarget & HTMLSelectElement };
	type TextInputEvent = Event & { currentTarget: EventTarget & HTMLInputElement };

	let { settings, settingsError, settingsSaved }: Props = $props();
	let settingsText = $state('');
	let lastHydratedSettingsText = $state('');
	let settingsControlError = $state('');
	const settingsFromServerText = $derived(JSON.stringify(settings ?? {}, null, 2));
	const QUICK_CONTROL_ERROR = 'Settings JSON must be a valid JSON object to use quick controls.';

	$effect(() => {
		if (settingsFromServerText !== lastHydratedSettingsText) {
			settingsText = settingsFromServerText;
			lastHydratedSettingsText = settingsFromServerText;
			settingsControlError = '';
		}
	});

	const DEFAULT_EMBEDDERS: Record<string, unknown> = {
		default: {
			source: 'userProvided',
			dimensions: 384
		}
	};

	const DEFAULT_HYBRID: Record<string, unknown> = {
		semanticRatio: 0.5
	};

	function isRecord(value: unknown): value is Record<string, unknown> {
		return typeof value === 'object' && value !== null && !Array.isArray(value);
	}

	function getEmbedderEntries(value: unknown): [string, Record<string, unknown>][] {
		if (!isRecord(value)) return [];
		return Object.entries(value).filter((entry): entry is [string, Record<string, unknown>] =>
			isRecord(entry[1])
		);
	}

	function getEmbedderDraftEntry(
		draft: Record<string, unknown>,
		name: string
	): Record<string, unknown> | null {
		const embedders = draft.embedders;
		if (!isRecord(embedders)) return null;
		const entry = embedders[name];
		return isRecord(entry) ? entry : null;
	}

	function createDefaultHybridSettings(draft: Record<string, unknown>): Record<string, unknown> {
		const firstEmbedderName = getEmbedderEntries(draft.embedders)[0]?.[0];
		return {
			...DEFAULT_HYBRID,
			embedder: firstEmbedderName ?? 'default'
		};
	}

	function parseOptionalInteger(value: string): number | null {
		if (value.trim().length === 0) return null;
		const parsed = Number.parseInt(value, 10);
		return Number.isNaN(parsed) ? null : parsed;
	}

	function parseSettingsDraft(): Record<string, unknown> | null {
		try {
			const parsed: unknown = JSON.parse(settingsText);
			return isRecord(parsed) ? parsed : null;
		} catch {
			return null;
		}
	}

	function updateSettingsDraft(mutator: (draft: Record<string, unknown>) => void): void {
		const parsed = parseSettingsDraft();
		if (!parsed) {
			settingsControlError = QUICK_CONTROL_ERROR;
			return;
		}
		mutator(parsed);
		settingsText = JSON.stringify(parsed, null, 2);
		settingsControlError = '';
	}

	function updateHybridDraft(
		draft: Record<string, unknown>,
		updateHybrid: (hybrid: Record<string, unknown>) => void
	): void {
		const hybrid = draft.hybrid;
		if (!isRecord(hybrid)) return;
		updateHybrid(hybrid);
	}

	function setMode(mode: string): void {
		updateSettingsDraft((draft) => {
			draft.mode = mode;
		});
	}

	function setEmbeddersEnabled(enabled: boolean): void {
		updateSettingsDraft((draft) => {
			if (enabled) {
				draft.embedders = isRecord(draft.embedders) ? draft.embedders : DEFAULT_EMBEDDERS;
				return;
			}

			delete draft.embedders;
			delete draft.hybrid;
		});
	}

	function setHybridEnabled(enabled: boolean): void {
		updateSettingsDraft((draft) => {
			if (enabled) {
				draft.hybrid = isRecord(draft.hybrid) ? draft.hybrid : createDefaultHybridSettings(draft);
				return;
			}

			delete draft.hybrid;
		});
	}

	function setHybridSemanticRatio(value: string): void {
		const semanticRatio = Number.parseFloat(value);
		updateSettingsDraft((draft) => {
			updateHybridDraft(draft, (hybrid) => {
				hybrid.semanticRatio = semanticRatio;
			});
		});
	}

	function setHybridEmbedder(embedder: string): void {
		updateSettingsDraft((draft) => {
			updateHybridDraft(draft, (hybrid) => {
				hybrid.embedder = embedder;
			});
		});
	}

	function setReRankingEnabled(enabled: boolean): void {
		updateSettingsDraft((draft) => {
			draft.enableReRanking = enabled;
		});
	}

	function setReRankingApplyFilter(filterValue: string): void {
		updateSettingsDraft((draft) => {
			const filter = filterValue.trim();
			if (filter.length > 0) {
				draft.reRankingApplyFilter = filter;
				return;
			}

			delete draft.reRankingApplyFilter;
		});
	}

	function setEmbedderSource(name: string, source: string): void {
		updateSettingsDraft((draft) => {
			const entry = getEmbedderDraftEntry(draft, name);
			if (entry) entry.source = source;
		});
	}

	function setEmbedderDimensions(name: string, value: string): void {
		const nextDimensions = parseOptionalInteger(value);
		updateSettingsDraft((draft) => {
			const entry = getEmbedderDraftEntry(draft, name);
			if (!entry) return;
			if (nextDimensions === null) {
				delete entry.dimensions;
				return;
			}

			entry.dimensions = nextDimensions;
		});
	}

	function handleModeChange(event: SelectChangeEvent): void {
		setMode(event.currentTarget.value);
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

	const parsedSettings = $derived(parseSettingsDraft());
	const modeValue = $derived(
		typeof parsedSettings?.mode === 'string' && parsedSettings.mode.length > 0
			? parsedSettings.mode
			: 'standard'
	);
	const embeddersEnabled = $derived(isRecord(parsedSettings?.embedders));
	const hybridSettings = $derived(isRecord(parsedSettings?.hybrid) ? parsedSettings.hybrid : null);
	const hybridEnabled = $derived(hybridSettings !== null);
	const reRankingEnabled = $derived(parsedSettings?.enableReRanking === true);
	const reRankingApplyFilterValue = $derived(
		typeof parsedSettings?.reRankingApplyFilter === 'string'
			? parsedSettings.reRankingApplyFilter
			: ''
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
	const embedderEntries = $derived(getEmbedderEntries(parsedSettings?.embedders));
	const hybridEmbedderOptions = $derived.by(() => {
		const names = embedderEntries.map(([name]) => name);

		return names.includes(hybridEmbedderValue) ? names : [...names, hybridEmbedderValue];
	});
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="settings-section">
	<h2 class="mb-4 text-lg font-medium text-gray-900">Settings</h2>
	<p class="mb-4 text-sm text-gray-600">
		Update index settings as JSON. Changes are forwarded directly to the index API.
	</p>

	{#if settingsSaved}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Settings saved.
		</div>
	{/if}

	{#if settingsError}
		<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{settingsError}</div>
	{/if}

	<form method="POST" action="?/saveSettings" use:enhance>
		<div class="mb-6 rounded-md border border-gray-200 p-4">
			<h3 class="mb-3 text-sm font-semibold text-gray-900">Vector, Hybrid, and Re-ranking</h3>
			<p class="mb-4 text-sm text-gray-600">
				These controls update the same Settings JSON draft below before save.
			</p>

			{#if settingsControlError}
				<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{settingsControlError}</div>
			{/if}

			<div class="grid grid-cols-1 gap-4 md:grid-cols-2">
				<div>
					<label for="settings-mode" class="mb-1 block text-sm font-medium text-gray-700"
						>Mode</label
					>
					<select
						id="settings-mode"
						value={modeValue}
						onchange={handleModeChange}
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					>
						<option value="standard">standard</option>
						<option value="neuralSearch">neuralSearch</option>
					</select>
				</div>

				<div class="flex flex-col gap-3">
					<label class="inline-flex items-center gap-2 text-sm text-gray-700">
						<input type="checkbox" checked={embeddersEnabled} onchange={handleEmbeddersToggle} />
						<span>Enable Embedders</span>
					</label>

					<label class="inline-flex items-center gap-2 text-sm text-gray-700">
						<input type="checkbox" checked={hybridEnabled} onchange={handleHybridToggle} />
						<span>Enable Hybrid Search</span>
					</label>

					{#if hybridEnabled}
						<div class="ml-6 flex flex-col gap-3">
							<div>
								<label for="settings-semantic-ratio" class="mb-1 block text-sm text-gray-700"
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
								<span class="text-xs text-gray-500">{semanticRatioValue}</span>
							</div>
							<div>
								<label for="settings-hybrid-embedder" class="mb-1 block text-sm text-gray-700"
									>Hybrid Embedder</label
								>
								<select
									id="settings-hybrid-embedder"
									value={hybridEmbedderValue}
									onchange={(event) =>
										setHybridEmbedder((event.currentTarget as HTMLSelectElement).value)}
									class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
								>
									{#each hybridEmbedderOptions as name (name)}
										<option value={name}>{name}</option>
									{/each}
								</select>
							</div>
						</div>
					{/if}

					<label class="inline-flex items-center gap-2 text-sm text-gray-700">
						<input type="checkbox" checked={reRankingEnabled} onchange={handleReRankingToggle} />
						<span>Enable Re-ranking</span>
					</label>

					<div>
						<label for="settings-reranking-filter" class="mb-1 block text-sm text-gray-700">
							Re-ranking Apply Filter
						</label>
						<input
							id="settings-reranking-filter"
							type="text"
							value={reRankingApplyFilterValue}
							oninput={handleReRankingApplyFilterInput}
							placeholder="brand:Nike"
							class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
						/>
					</div>
				</div>
			</div>
		</div>

		{#if embeddersEnabled && embedderEntries.length > 0}
			<div class="mb-6 rounded-md border border-gray-200 p-4">
				<h3 class="mb-3 text-sm font-semibold text-gray-900">Embedder Configuration</h3>
				{#each embedderEntries as [name, config] (name)}
					<div class="mb-3 rounded-md border border-gray-100 p-3">
						<span class="mb-2 block text-sm font-medium text-gray-800">{name}</span>
						<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
							<div>
								<label for="embedder-{name}-source" class="mb-1 block text-sm text-gray-700"
									>{name} source</label
								>
								<select
									id="embedder-{name}-source"
									value={typeof config.source === 'string' ? config.source : ''}
									onchange={(event) =>
										setEmbedderSource(name, (event.currentTarget as HTMLSelectElement).value)}
									class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
								>
									<option value="userProvided">userProvided</option>
									<option value="openAi">openAi</option>
									<option value="huggingFace">huggingFace</option>
									<option value="ollama">ollama</option>
									<option value="rest">rest</option>
								</select>
							</div>
							<div>
								<label for="embedder-{name}-dimensions" class="mb-1 block text-sm text-gray-700"
									>{name} dimensions</label
								>
								<input
									id="embedder-{name}-dimensions"
									type="number"
									value={typeof config.dimensions === 'number' ? config.dimensions : ''}
									oninput={(event) =>
										setEmbedderDimensions(name, (event.currentTarget as HTMLInputElement).value)}
									class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
								/>
							</div>
						</div>
					</div>
				{/each}
			</div>
		{/if}

		<label for="settings-json" class="mb-2 block text-sm font-medium text-gray-700"
			>Settings JSON</label
		>
		<textarea
			id="settings-json"
			name="settings"
			aria-label="Settings JSON"
			bind:value={settingsText}
			rows="16"
			class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
		></textarea>
		<button
			type="submit"
			class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
		>
			Save Settings
		</button>
	</form>
</div>
