<script lang="ts">
	import { applyAction, deserialize } from '$app/forms';
	import { invalidateAll } from '$app/navigation';
	import type { ActionResult } from '@sveltejs/kit';
	import type {
		AlgoliaMigrationCapabilities,
		PublicAlgoliaImportJob,
		ResumeAlgoliaImportJobRequest
	} from '$lib/api/types';
	import ImportJobDetail from '$lib/components/migration/ImportJobDetail.svelte';
	import { describeAlgoliaImportStatus } from '$lib/components/migration/job_presentation';

	// The server load owns the job and its capabilities. While the import is
	// running we reload that load function on an interval so the server-owned
	// getAlgoliaImportJob result stays the single source of truth — the browser
	// never polls the control plane or holds a second capability source.
	const JOB_POLL_INTERVAL_MS = 4000;

	let { data } = $props<{
		data: {
			job: PublicAlgoliaImportJob;
			capabilities: AlgoliaMigrationCapabilities;
		};
	}>();

	const job = $derived(data.job);
	const capabilities = $derived(data.capabilities);
	const running = $derived(describeAlgoliaImportStatus(job.status).running);

	let reloading = $state(false);

	async function refreshJob(): Promise<void> {
		if (reloading) return;
		reloading = true;
		try {
			await invalidateAll();
		} finally {
			reloading = false;
		}
	}

	$effect(() => {
		if (!running) return;
		const handle = setInterval(() => {
			void refreshJob();
		}, JOB_POLL_INTERVAL_MS);
		return () => clearInterval(handle);
	});

	async function submitJobAction(actionName: 'cancel' | 'resume', body: FormData): Promise<void> {
		const response = await fetch(`?/${actionName}`, {
			method: 'POST',
			headers: { 'x-sveltekit-action': 'true' },
			body
		});
		const result = deserialize(await response.text()) as ActionResult;
		if (result.type === 'success') {
			await refreshJob();
			return;
		}
		await applyAction(result);
	}

	function handleCancelIntent(): void {
		void submitJobAction('cancel', new FormData());
	}

	function handleResumeIntent(request: ResumeAlgoliaImportJobRequest): void {
		const body = new FormData();
		body.set('apiKey', request.apiKey);
		void submitJobAction('resume', body);
	}
</script>

<svelte:head>
	<title>Algolia import · {job.source.name}</title>
</svelte:head>

<div class="space-y-6">
	<ImportJobDetail
		{job}
		{capabilities}
		{reloading}
		onCancelIntent={handleCancelIntent}
		onResumeIntent={handleResumeIntent}
	/>
</div>
