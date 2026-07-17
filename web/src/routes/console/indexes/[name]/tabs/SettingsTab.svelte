<script lang="ts">
	import { enhance } from '$app/forms';
	import { pushState } from '$app/navigation';
	import { page } from '$app/state';
	import type { ResolvedPathname } from '$app/types';
	import { browser } from '$app/environment';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import AdvancedJsonSettings from './settings/AdvancedJsonSettings.svelte';
	import SearchSettings from './settings/SearchSettings.svelte';
	import RankingSettings from './settings/RankingSettings.svelte';
	import LanguageTextSettings from './settings/LanguageTextSettings.svelte';
	import FacetsFiltersSettings from './settings/FacetsFiltersSettings.svelte';
	import DisplaySettings from './settings/DisplaySettings.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import {
		getChangedReindexRiskFields,
		parseSettingsDraftText,
		resetSettingsDraftText,
		stringifySettingsDraft,
		updateSettingsDraftText,
		type SettingsDraftMutator
	} from './settings/settings_draft';

	type Props = {
		settings: Record<string, unknown> | null;
		settingsError: string;
		settingsSaved: boolean;
	};

	type SettingsSubtabId =
		| 'search'
		| 'ranking'
		| 'language-text'
		| 'facets-filters'
		| 'display'
		| 'advanced-json';

	type SettingsSubtab = {
		id: SettingsSubtabId;
		label: string;
		panelId: string;
	};

	let { settings, settingsError, settingsSaved }: Props = $props();
	let settingsText = $state('');
	let lastHydratedSettingsText = $state('');
	let settingsControlError = $state('');
	let activeSettingsTab = $derived<SettingsSubtabId>(
		normalizeSettingsSubtab(page.url.searchParams.get('settingsTab'))
	);
	let lastSettingsSavedToastState = $state(false);

	const SETTINGS_SUBTABS: SettingsSubtab[] = [
		{ id: 'search', label: 'Search', panelId: 'settings-panel-search' },
		{ id: 'ranking', label: 'Ranking', panelId: 'settings-panel-ranking' },
		{ id: 'language-text', label: 'Language & Text', panelId: 'settings-panel-language-text' },
		{
			id: 'facets-filters',
			label: 'Facets & Filters',
			panelId: 'settings-panel-facets-filters'
		},
		{ id: 'display', label: 'Display', panelId: 'settings-panel-display' },
		{ id: 'advanced-json', label: 'Advanced JSON', panelId: 'settings-panel-advanced-json' }
	];

	const SETTINGS_SUBTAB_IDS = new Set<SettingsSubtabId>(SETTINGS_SUBTABS.map((tab) => tab.id));
	const settingsFromServerText = $derived(stringifySettingsDraft(settings));
	const parsedSettings = $derived(parseSettingsDraftText(settingsText));
	const hasDraftChanges = $derived(settingsText !== settingsFromServerText);

	let settingsForm = $state<HTMLFormElement | null>(null);
	let saveButtonRef = $state<HTMLButtonElement | null>(null);
	let showReindexWarning = $state(false);
	let changedRiskyFields = $state<string[]>([]);

	$effect(() => {
		if (settingsFromServerText !== lastHydratedSettingsText) {
			settingsText = settingsFromServerText;
			lastHydratedSettingsText = settingsFromServerText;
			settingsControlError = '';
		}
	});

	$effect(() => {
		if (settingsSaved && !lastSettingsSavedToastState) {
			toast.success('Settings saved.', { duration: TOAST_DURATION_MS });
		}
		lastSettingsSavedToastState = settingsSaved;
	});

	function normalizeSettingsSubtab(rawTab: string | null): SettingsSubtabId {
		if (!rawTab) return 'search';
		return SETTINGS_SUBTAB_IDS.has(rawTab as SettingsSubtabId)
			? (rawTab as SettingsSubtabId)
			: 'search';
	}

	function buildSettingsSubtabHref(
		currentUrl: URL,
		settingsTab: SettingsSubtabId
	): ResolvedPathname {
		const nextSearchParams = new SvelteURLSearchParams(currentUrl.searchParams);
		nextSearchParams.set('tab', 'settings');
		nextSearchParams.set('settingsTab', settingsTab);
		return `${currentUrl.pathname}?${nextSearchParams.toString()}` as ResolvedPathname;
	}

	function currentNavigationUrl(): URL {
		return browser ? new URL(window.location.href) : page.url;
	}

	function activateSettingsSubtab(settingsTab: SettingsSubtabId): void {
		if (browser) {
			// eslint-disable-next-line svelte/no-navigation-without-resolve -- settings subtabs preserve the current dynamic pathname and only update query params, which resolve() rejects.
			pushState(buildSettingsSubtabHref(currentNavigationUrl(), settingsTab), {});
		}

		activeSettingsTab = settingsTab;
	}

	function focusSettingsSubtab(settingsTab: SettingsSubtabId): void {
		document.getElementById(`settings-tab-${settingsTab}`)?.focus();
	}

	function handleSettingsSubtabKeydown(event: KeyboardEvent, settingsTab: SettingsSubtabId): void {
		const currentIndex = SETTINGS_SUBTABS.findIndex((tab) => tab.id === settingsTab);
		const lastIndex = SETTINGS_SUBTABS.length - 1;
		let nextIndex: number | null = null;

		if (event.key === 'ArrowRight') nextIndex = currentIndex === lastIndex ? 0 : currentIndex + 1;
		if (event.key === 'ArrowLeft') nextIndex = currentIndex === 0 ? lastIndex : currentIndex - 1;
		if (event.key === 'Home') nextIndex = 0;
		if (event.key === 'End') nextIndex = lastIndex;
		if (nextIndex === null) return;

		event.preventDefault();
		focusSettingsSubtab(SETTINGS_SUBTABS[nextIndex].id);
	}

	function updateSettingsDraft(mutator: SettingsDraftMutator): void {
		const result = updateSettingsDraftText(settingsText, mutator);
		settingsText = result.settingsText;
		settingsControlError = result.error;
	}

	function resetSettingsDraftToServerValue(): void {
		settingsText = resetSettingsDraftText(settings);
		settingsControlError = '';
	}

	function submitSettingsForm(): void {
		settingsForm?.requestSubmit();
	}

	function handleSaveSettingsClick(): void {
		if (parsedSettings === null) {
			changedRiskyFields = [];
			submitSettingsForm();
			return;
		}
		changedRiskyFields = getChangedReindexRiskFields(settings, parsedSettings);
		if (changedRiskyFields.length === 0) {
			submitSettingsForm();
			return;
		}
		showReindexWarning = true;
	}

	function confirmReindexSave(): void {
		showReindexWarning = false;
		submitSettingsForm();
	}

	function cancelReindexSave(): void {
		showReindexWarning = false;
	}
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow">
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Settings</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Update index settings as JSON. Changes are forwarded directly to the index API.
	</p>

	{#if settingsError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{settingsError}
		</div>
	{/if}

	<form method="POST" action="?/saveSettings" use:enhance bind:this={settingsForm}>
		<div class="mb-6">
			<div
				role="tablist"
				aria-label="Settings sections"
				class="mb-4 flex flex-wrap gap-1 rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/40 p-1"
			>
				{#each SETTINGS_SUBTABS as tab (tab.id)}
					<button
						id="settings-tab-{tab.id}"
						type="button"
						role="tab"
						aria-selected={activeSettingsTab === tab.id}
						aria-controls={tab.panelId}
						tabindex={activeSettingsTab === tab.id ? 0 : -1}
						onclick={() => activateSettingsSubtab(tab.id)}
						onkeydown={(event) => handleSettingsSubtabKeydown(event, tab.id)}
						class="rounded-md px-3 py-2 text-sm font-medium {activeSettingsTab === tab.id
							? 'bg-flapjack-rose text-white'
							: 'text-flapjack-ink/80 hover:bg-white'}"
					>
						{tab.label}
					</button>
				{/each}
			</div>

			{#if settingsControlError}
				<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
					{settingsControlError}
				</div>
			{/if}

			<div
				id="settings-panel-search"
				role="tabpanel"
				aria-labelledby="settings-tab-search"
				aria-label="Search"
				hidden={activeSettingsTab !== 'search'}
				class="rounded-md border border-flapjack-ink/20 p-4"
			>
				<SearchSettings draft={parsedSettings} {updateSettingsDraft} />
			</div>

			<div
				id="settings-panel-ranking"
				role="tabpanel"
				aria-labelledby="settings-tab-ranking"
				aria-label="Ranking"
				hidden={activeSettingsTab !== 'ranking'}
				class="rounded-md border border-flapjack-ink/20 p-4"
			>
				<RankingSettings draft={parsedSettings} {updateSettingsDraft} />
			</div>

			<div
				id="settings-panel-language-text"
				role="tabpanel"
				aria-labelledby="settings-tab-language-text"
				aria-label="Language & Text"
				hidden={activeSettingsTab !== 'language-text'}
				class="rounded-md border border-flapjack-ink/20 p-4"
			>
				<LanguageTextSettings />
			</div>

			<div
				id="settings-panel-facets-filters"
				role="tabpanel"
				aria-labelledby="settings-tab-facets-filters"
				aria-label="Facets & Filters"
				hidden={activeSettingsTab !== 'facets-filters'}
				class="rounded-md border border-flapjack-ink/20 p-4"
			>
				<FacetsFiltersSettings draft={parsedSettings} {updateSettingsDraft} />
			</div>

			<div
				id="settings-panel-display"
				role="tabpanel"
				aria-labelledby="settings-tab-display"
				aria-label="Display"
				hidden={activeSettingsTab !== 'display'}
				class="rounded-md border border-flapjack-ink/20 p-4"
			>
				<DisplaySettings draft={parsedSettings} {updateSettingsDraft} />
			</div>

			<div
				id="settings-panel-advanced-json"
				role="tabpanel"
				aria-labelledby="settings-tab-advanced-json"
				aria-label="Advanced JSON"
				hidden={activeSettingsTab !== 'advanced-json'}
				class="rounded-md border border-flapjack-ink/20 p-4"
			>
				<AdvancedJsonSettings draft={parsedSettings} {updateSettingsDraft} />
			</div>
		</div>

		<label for="settings-json" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
			>Settings JSON</label
		>
		<textarea
			id="settings-json"
			name="settings"
			aria-label="Settings JSON"
			bind:value={settingsText}
			rows="16"
			class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		></textarea>
		<div class="flex items-center gap-2">
			{#if hasDraftChanges}
				<button
					data-testid="settings-reset-button"
					type="button"
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
					onclick={resetSettingsDraftToServerValue}
				>
					Reset
				</button>
			{/if}
			<button
				bind:this={saveButtonRef}
				type="button"
				onclick={handleSaveSettingsClick}
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Save Settings
			</button>
		</div>
	</form>
</div>

<ConfirmDialog
	open={showReindexWarning}
	mode="standard"
	dangerLevel="warn"
	title="Confirm reindex"
	entityName="index settings"
	consequences={`Saving will trigger a full reindex because these fields changed: ${changedRiskyFields.join(', ')}.`}
	confirmLabel="Save and reindex"
	cancelLabel="Cancel"
	onConfirm={confirmReindexSave}
	onCancel={cancelReindexSave}
	triggerRef={saveButtonRef}
/>
