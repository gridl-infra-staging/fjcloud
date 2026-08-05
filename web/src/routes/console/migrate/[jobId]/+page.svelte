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
	import MigrationCutoverVerification from '$lib/components/migration/MigrationCutoverVerification.svelte';
	import { describeAlgoliaImportStatus } from '$lib/components/migration/job_presentation';
	import {
		createMigrationCutoverVerificationState,
		requestMigrationCutoverVerification,
		type MigrationCutoverVerificationActionResult,
		type MigrationCutoverVerificationInputs,
		type MigrationCutoverVerificationIntent
	} from '$lib/components/migration/migration_cutover_verification_state';

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
	let cutoverVerification = $state(createMigrationCutoverVerificationState());
	let verificationInputs = $state<MigrationCutoverVerificationInputs>({
		queries: ['running shoes'],
		resultLimit: 10
	});
	const currentVerificationBinding = $derived(verificationBinding(verificationInputs));
	const visibleVerificationReport = $derived(
		cutoverVerification.binding === currentVerificationBinding ? cutoverVerification.result : null
	);
	const visibleVerificationError = $derived(
		cutoverVerification.attemptBinding === currentVerificationBinding
			? cutoverVerification.error
			: null
	);

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
		const body = new FormData();
		body.set('source_provider', job.sourceProvider);
		void submitJobAction('cancel', body);
	}

	function handleResumeIntent(request: ResumeAlgoliaImportJobRequest): void {
		const body = new FormData();
		body.set('source_provider', job.sourceProvider);
		body.set('apiKey', request.apiKey);
		void submitJobAction('resume', body);
	}

	function verificationBinding(inputs: MigrationCutoverVerificationInputs): string {
		return [
			job.id,
			job.status,
			job.sourceProvider,
			job.source.name,
			job.destination.target,
			String(inputs.resultLimit),
			inputs.queries.join('\u0000')
		].join('\u0001');
	}

	async function submitVerificationAction(
		request: MigrationCutoverVerificationIntent
	): Promise<MigrationCutoverVerificationActionResult> {
		const body = new FormData();
		body.set('source_provider', job.sourceProvider);
		body.set('appId', request.appId);
		body.set('apiKey', request.apiKey);
		body.set('queries', request.queries.join('\n'));
		body.set('resultLimit', String(request.resultLimit));
		const response = await fetch('?/verify', {
			method: 'POST',
			headers: { 'x-sveltekit-action': 'true' },
			body
		});
		const result = deserialize(await response.text()) as ActionResult;
		if (result.type === 'success' && result.data) {
			return result.data as MigrationCutoverVerificationActionResult;
		}
		if (result.type === 'failure' && result.data) {
			if (result.data._authSessionExpired === true) {
				await applyAction(result);
				return { actionApplied: true };
			}
			return normalizeVerificationFailure(result.data);
		}
		await applyAction(result);
		return { actionApplied: true };
	}

	function normalizeVerificationFailure(
		data: Record<string, unknown>
	): MigrationCutoverVerificationActionResult {
		return {
			error: {
				code: typeof data.code === 'string' ? data.code : null,
				message:
					typeof data.message === 'string'
						? data.message
						: typeof data.error === 'string'
							? data.error
							: null
			}
		};
	}

	function handleVerificationInputsChange(inputs: MigrationCutoverVerificationInputs): void {
		verificationInputs = inputs;
	}

	function handleVerifyIntent(request: MigrationCutoverVerificationIntent): Promise<void> {
		verificationInputs = { queries: request.queries, resultLimit: request.resultLimit };
		const binding = verificationBinding(verificationInputs);
		return requestMigrationCutoverVerification(cutoverVerification, {
			currentBinding: () => verificationBinding(verificationInputs),
			prepare: () => ({
				binding,
				redactions: [request.appId, request.apiKey],
				submit: () => submitVerificationAction(request)
			})
		});
	}
</script>

<svelte:head>
	<title>Migration import · {job.source.name}</title>
</svelte:head>

<div class="space-y-6">
	<ImportJobDetail
		{job}
		{capabilities}
		{reloading}
		onCancelIntent={handleCancelIntent}
		onResumeIntent={handleResumeIntent}
	/>
	<MigrationCutoverVerification
		{job}
		report={visibleVerificationReport}
		error={visibleVerificationError}
		activeRequest={cutoverVerification.activeRequest}
		verifySupported={capabilities.verify === true}
		onVerifyIntent={handleVerifyIntent}
		onVerificationInputsChange={handleVerificationInputsChange}
	/>
</div>
