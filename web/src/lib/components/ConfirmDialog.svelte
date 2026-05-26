<script lang="ts">
	import { tick } from 'svelte';

	type ConfirmMode = 'standard' | 'typed';
	type DangerLevel = 'warn' | 'severe';

	interface Props {
		open: boolean;
		mode: ConfirmMode;
		dangerLevel: DangerLevel;
		title: string;
		consequences: string;
		rationale?: string;
		entityName: string;
		typedPhrase?: string;
		confirmLabel?: string;
		cancelLabel?: string;
		onConfirm?: () => Promise<void> | void;
		onCancel?: () => void;
		triggerRef?: HTMLElement | null;
	}

	let {
		open,
		mode,
		dangerLevel,
		title,
		consequences,
		rationale = '',
		entityName,
		typedPhrase,
		confirmLabel = 'Confirm',
		cancelLabel = 'Cancel',
		onConfirm = async () => {},
		onCancel = () => {},
		triggerRef = null
	}: Props = $props();

	let typedInputValue = $state('');
	let confirmAttempted = $state(false);
	let isConfirming = $state(false);
	let errorMessage = $state<string | null>(null);
	let cancelButtonRef = $state<HTMLButtonElement | null>(null);
	let confirmButtonRef = $state<HTMLButtonElement | null>(null);
	let inputRef = $state<HTMLInputElement | null>(null);
	let lastOpenTriggerRef = $state<HTMLElement | null>(null);

	let previousOpen = false;
	let previousMode: ConfirmMode = 'standard';

	function toStableIdFragment(value: string): string {
		const normalized = value
			.toLowerCase()
			.trim()
			.replace(/[^a-z0-9]+/g, '-')
			.replace(/^-+|-+$/g, '');
		return normalized.length > 0 ? normalized : 'dialog';
	}

	const dialogId = $derived.by(() => {
		const baseParts = [entityName, typedPhrase ?? '', mode, dangerLevel];
		return toStableIdFragment(baseParts.join('-'));
	});
	const titleId = $derived(`confirm-dialog-title-${dialogId}`);
	const consequencesId = $derived(`confirm-dialog-consequences-${dialogId}`);
	const rationaleId = $derived(`confirm-dialog-rationale-${dialogId}`);
	const irreversibleId = $derived(`confirm-dialog-irreversible-${dialogId}`);
	const confirmInputId = $derived(`confirm-dialog-input-${dialogId}`);
	const mismatchHintId = $derived(`confirm-dialog-mismatch-${dialogId}`);

	const dialogRole = $derived(dangerLevel === 'severe' ? 'alertdialog' : 'dialog');
	const requiredPhrase = $derived((typedPhrase ?? entityName).trim());
	const isTypedMode = $derived(mode === 'typed');
	const isTypedPhraseMatch = $derived(typedInputValue.trim() === requiredPhrase);
	const isConfirmDisabled = $derived(isConfirming || (isTypedMode && !isTypedPhraseMatch));
	const showMismatchHint = $derived(isTypedMode && confirmAttempted && typedInputValue.length > 0 && !isTypedPhraseMatch);
	const dialogDescribedBy = $derived.by(() => {
		const describedBy = [consequencesId];
		if (rationale.trim().length > 0) {
			describedBy.push(rationaleId);
		}
		if (dangerLevel === 'severe') {
			describedBy.push(irreversibleId);
		}
		return describedBy.join(' ');
	});

	function extractErrorMessage(error: unknown): string {
		if (error instanceof Error && error.message.trim().length > 0) {
			return error.message;
		}
		if (typeof error === 'string' && error.trim().length > 0) {
			return error;
		}
		return 'Request failed. Please try again.';
	}

	function resetTypedInputState(): void {
		typedInputValue = '';
		confirmAttempted = false;
	}

	function focusReturnTarget(): void {
		const triggerCandidate = triggerRef ?? lastOpenTriggerRef;

		// Prefer the trigger, but only treat it as handled if focus actually landed there.
		// A still-mounted but unfocusable trigger (disabled/hidden) is a no-op for .focus(),
		// so fall through to the stable container rather than stranding focus on <body>.
		if (triggerCandidate && document.contains(triggerCandidate)) {
			triggerCandidate.focus();
			if (document.activeElement === triggerCandidate) {
				return;
			}
		}

		const fallback = document.querySelector<HTMLElement>('[role="main"], h1, h2');
		if (!fallback) {
			return;
		}

		fallback.focus();
		if (document.activeElement === fallback) {
			return;
		}

		// Ensure semantic containers can become a deterministic focus target when triggerRef disappears.
		if (fallback.getAttribute('tabindex') === null) {
			fallback.setAttribute('tabindex', '-1');
		}
		fallback.focus();
	}

	async function focusDefaultTarget(): Promise<void> {
		await tick();
		if (!open || isConfirming) {
			return;
		}
		if (isTypedMode) {
			inputRef?.focus();
			return;
		}
		cancelButtonRef?.focus();
	}

	$effect(() => {
		const justOpened = open && (!previousOpen || mode !== previousMode);
		const justClosed = !open && previousOpen;
		previousOpen = open;
		previousMode = mode;

		if (open && triggerRef && document.contains(triggerRef)) {
			lastOpenTriggerRef = triggerRef;
		}

		if (justOpened) {
			void focusDefaultTarget();
		}

		if (justClosed) {
			focusReturnTarget();
			lastOpenTriggerRef = null;
			resetTypedInputState();
			isConfirming = false;
			errorMessage = null;
		}
	});

	async function runConfirmAction(): Promise<void> {
		if (isConfirmDisabled) {
			return;
		}
		confirmAttempted = true;
		errorMessage = null;
		isConfirming = true;

		try {
			await onConfirm();
		} catch (error) {
			errorMessage = extractErrorMessage(error);
		} finally {
			isConfirming = false;
		}
	}

	function handleCancel(): void {
		if (isConfirming) {
			return;
		}
		errorMessage = null;
		resetTypedInputState();
		onCancel();
	}

	function handleDialogKeydown(event: KeyboardEvent): void {
		if (event.key === 'Escape') {
			event.preventDefault();
			handleCancel();
			return;
		}

		if (event.key !== 'Enter' || isConfirming) {
			return;
		}

		const eventTarget = event.target;
		if (isTypedMode) {
			if (eventTarget instanceof HTMLInputElement && isTypedPhraseMatch) {
				event.preventDefault();
				void runConfirmAction();
			}
			return;
		}

		if (eventTarget instanceof HTMLInputElement || eventTarget instanceof HTMLTextAreaElement) {
			return;
		}
		if (eventTarget === cancelButtonRef) {
			return;
		}
		if (eventTarget instanceof HTMLButtonElement && eventTarget !== confirmButtonRef) {
			return;
		}

		event.preventDefault();
		void runConfirmAction();
	}

	function handleBackdropClick(event: MouseEvent): void {
		if (dangerLevel === 'severe' || isConfirming) {
			return;
		}

		if (event.target === event.currentTarget) {
			handleCancel();
		}
	}

	function mountNativeModalOwner(node: HTMLDialogElement): { destroy: () => void } {
		if (typeof node.showModal === 'function') {
			try {
				node.showModal();
			} catch {
				// SSR may pre-render <dialog open>, which causes showModal() to throw because
				// the element is already open in non-modal mode. Close and immediately reopen
				// so we preserve first paint while still upgrading to modal ownership.
				if (node.open && typeof node.close === 'function') {
					node.close();
					node.showModal();
				} else {
					node.setAttribute('open', '');
				}
			}
		} else {
			node.setAttribute('open', '');
		}
		return {
			destroy: () => {
				// Ensure dialog teardown always exits modal state before unmount.
				if (typeof node.close === 'function') {
					node.close();
					return;
				}
				node.removeAttribute('open');
			}
		};
	}
</script>

{#if open}
	<dialog
		aria-describedby={dialogDescribedBy}
		aria-labelledby={titleId}
		aria-modal="true"
		class="fixed inset-0 z-50 m-0 flex h-full w-full max-h-none max-w-none items-center justify-center border-0 bg-flapjack-ink/55 p-4"
		data-testid="confirm-dialog"
		open
		onclick={handleBackdropClick}
		onkeydown={handleDialogKeydown}
		role={dialogRole}
		use:mountNativeModalOwner
	>
		<div class="w-full max-w-lg rounded-lg border border-flapjack-ink/20 bg-white p-6 shadow-xl">
			<h2 class="text-lg font-semibold text-flapjack-plum" id={titleId}>
				{title}
			</h2>
			<p class="mt-2 text-sm text-flapjack-ink/80" id={consequencesId}>
				{consequences}
			</p>
			{#if rationale.trim().length > 0}
				<p class="mt-2 text-sm text-flapjack-ink/70" id={rationaleId}>
					{rationale}
				</p>
			{/if}
			{#if dangerLevel === 'severe'}
				<p class="mt-3 text-sm font-semibold text-flapjack-plum" id={irreversibleId}>
					This cannot be undone.
				</p>
			{/if}

			{#if isTypedMode}
				<label class="mt-4 block text-sm font-medium text-flapjack-ink/80" for={confirmInputId}>
					Type "{requiredPhrase}" to confirm
				</label>
				<input
					aria-describedby={showMismatchHint ? mismatchHintId : undefined}
					bind:this={inputRef}
					bind:value={typedInputValue}
					class="mt-2 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-plum focus:ring-1 focus:ring-flapjack-plum"
					data-testid="confirm-input"
					disabled={isConfirming}
					id={confirmInputId}
					type="text"
				/>
				{#if showMismatchHint}
					<p class="mt-2 text-xs text-flapjack-plum" id={mismatchHintId}>
						Must match exactly
					</p>
				{/if}
			{/if}

			{#if errorMessage}
				<div
					class="mt-4 rounded-md border border-flapjack-rose/45 bg-flapjack-rose/10 px-3 py-2 text-sm text-flapjack-plum"
					role="alert"
				>
					{errorMessage}
				</div>
			{/if}

			<div class="mt-5 flex flex-wrap justify-end gap-3">
				<button
					bind:this={cancelButtonRef}
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-60"
					data-testid="confirm-cancel-btn"
					disabled={isConfirming}
					onclick={handleCancel}
					type="button"
				>
					{cancelLabel}
				</button>
				<button
					aria-disabled={isConfirmDisabled}
					bind:this={confirmButtonRef}
					class="rounded-md bg-flapjack-plum px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum/90 disabled:cursor-not-allowed disabled:opacity-60"
					data-testid="confirm-confirm-btn"
					disabled={isConfirmDisabled}
					onclick={() => void runConfirmAction()}
					type="button"
				>
					{isConfirming ? 'Please wait…' : confirmLabel}
				</button>
			</div>
		</div>
	</dialog>
{/if}
