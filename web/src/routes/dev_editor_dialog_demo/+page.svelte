<script lang="ts">
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type {
		EditorDialogMode,
		EditorDialogOnSave,
		EditorDialogValues
	} from '$lib/components/EditorDialog.types';
	import { toast } from '$lib/toast';
	import { createSeedValue, demoSchema, editSeedValue } from './demo_contract';

	type DemoScenario = 'success' | 'reject' | 'pending';

	const DEMO_TOAST_TEXT = 'Shared toast rendered from demo route';

	let open = false;
	let mode: EditorDialogMode = 'create';
	let scenario: DemoScenario = 'success';
	let initialValue: EditorDialogValues = createSeedValue;
	let statusText = 'Idle';
	let lastPayloadText = '';
	let pendingResolver: (() => void) | null = null;

	function openCreateScenario(): void {
		mode = 'create';
		scenario = 'success';
		initialValue = createSeedValue;
		statusText = 'Idle';
		open = true;
	}

	function openEditScenario(): void {
		mode = 'edit';
		scenario = 'success';
		initialValue = editSeedValue;
		statusText = 'Idle';
		open = true;
	}

	function openDirtyDismissScenario(): void {
		mode = 'edit';
		scenario = 'success';
		initialValue = editSeedValue;
		statusText = 'Dirty dismiss scenario ready';
		open = true;
	}

	function openPendingSaveScenario(): void {
		mode = 'create';
		scenario = 'pending';
		initialValue = createSeedValue;
		statusText = 'Pending save scenario ready';
		open = true;
	}

	function openRejectedSaveScenario(): void {
		mode = 'create';
		scenario = 'reject';
		initialValue = createSeedValue;
		statusText = 'Rejected save scenario ready';
		open = true;
	}

	function openSuccessfulSaveScenario(): void {
		mode = 'create';
		scenario = 'success';
		initialValue = createSeedValue;
		statusText = 'Success scenario ready';
		open = true;
	}

	function resolvePendingSave(): void {
		pendingResolver?.();
		pendingResolver = null;
	}

	function triggerDemoToast(): void {
		toast.success(DEMO_TOAST_TEXT);
	}

	function formatPayload(payload: EditorDialogValues): string {
		return JSON.stringify(payload, null, 2);
	}

	const onSave: EditorDialogOnSave = async (payload) => {
		if (scenario === 'pending') {
			statusText = 'Save pending';
			await new Promise<void>((resolve) => {
				pendingResolver = resolve;
			});
			statusText = 'Pending save resolved';
		}

		if (scenario === 'reject') {
			statusText = 'Save rejected';
			throw new Error('Demo rejected save');
		}

		statusText = 'Save succeeded';
		lastPayloadText = formatPayload(payload);
		open = false;
	};

	function onCancel(): void {
		statusText = 'Dialog canceled';
		open = false;
	}
</script>

<h1>Editor Dialog Demo</h1>
<p data-testid="demo-status">{statusText}</p>

<div>
	<button type="button" data-testid="demo-open-create" on:click={openCreateScenario}
		>Open create mode</button
	>
	<button type="button" data-testid="demo-open-edit" on:click={openEditScenario}
		>Open edit mode</button
	>
	<button type="button" data-testid="demo-open-dirty-dismiss" on:click={openDirtyDismissScenario}
		>Open dirty dismiss</button
	>
	<button type="button" data-testid="demo-open-pending-save" on:click={openPendingSaveScenario}
		>Open pending save</button
	>
	<button type="button" data-testid="demo-open-rejected-save" on:click={openRejectedSaveScenario}
		>Open rejected save</button
	>
	<button
		type="button"
		data-testid="demo-open-successful-save"
		on:click={openSuccessfulSaveScenario}>Open successful save</button
	>
	<button type="button" data-testid="demo-resolve-pending-save" on:click={resolvePendingSave}
		>Resolve pending save</button
	>
	<button type="button" data-testid="demo-trigger-toast" on:click={triggerDemoToast}
		>Trigger toast</button
	>
</div>

<EditorDialog
	title={mode === 'create' ? 'Create Demo Rule' : 'Edit Demo Rule'}
	{mode}
	schema={demoSchema}
	{initialValue}
	{open}
	{onSave}
	{onCancel}
	description="Development harness for the editor dialog primitive"
	submitLabel={mode === 'create' ? 'Save Demo' : 'Update Demo'}
	testId="editor-dialog-demo"
/>

<h2>Last saved payload</h2>
<pre data-testid="demo-last-payload">{lastPayloadText}</pre>
