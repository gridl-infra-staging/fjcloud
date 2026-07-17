<script lang="ts">
	interface Props {
		triggerLabel: string;
		message: string;
		idBase?: string;
	}

	let { triggerLabel, message, idBase }: Props = $props();
	const componentId = $props.id();

	let isFocused = $state(false);
	let isHovered = $state(false);
	let isClickToggled = $state(false);
	let isDismissed = $state(false);
	let pointerToggleTarget = $state<boolean | null>(null);

	function toStableIdFragment(value: string): string {
		const normalized = value
			.toLowerCase()
			.trim()
			.replace(/[^a-z0-9]+/g, '-')
			.replace(/^-+|-+$/g, '');
		return normalized.length > 0 ? normalized : 'tooltip';
	}

	const idFragment = $derived.by(() => {
		if (idBase !== undefined) {
			return toStableIdFragment(idBase);
		}
		return `${toStableIdFragment(triggerLabel)}-${toStableIdFragment(componentId)}`;
	});
	const triggerId = $derived(`tooltip-trigger-${idFragment}`);
	const tooltipId = $derived(`tooltip-surface-${idFragment}`);
	const isVisible = $derived(!isDismissed && (isFocused || isHovered || isClickToggled));

	function focusTooltip(): void {
		isFocused = true;
		isDismissed = false;
	}

	function blurTooltip(): void {
		isFocused = false;
	}

	function hoverTooltip(): void {
		isHovered = true;
		isDismissed = false;
	}

	function leaveTooltip(): void {
		isHovered = false;
	}

	function capturePointerToggleTarget(): void {
		pointerToggleTarget = !isVisible;
	}

	function toggleTooltip(): void {
		const shouldShow = pointerToggleTarget ?? !isVisible;
		isClickToggled = shouldShow;
		isDismissed = !shouldShow;
		pointerToggleTarget = null;
	}

	function hideTooltip(): void {
		isFocused = false;
		isHovered = false;
		isClickToggled = false;
		isDismissed = false;
		pointerToggleTarget = null;
	}

	function dismissOnEscape(event: KeyboardEvent): void {
		if (event.key !== 'Escape') return;
		event.preventDefault();
		hideTooltip();
	}
</script>

<span class="relative inline-flex items-center">
	<button
		id={triggerId}
		type="button"
		class="inline-flex h-7 w-7 items-center justify-center rounded-full border border-flapjack-ink/25 text-sm font-semibold text-flapjack-ink/70 hover:bg-flapjack-cream/80 hover:text-flapjack-ink focus:ring-2 focus:ring-flapjack-rose focus:ring-offset-2 focus:ring-offset-white"
		aria-label={triggerLabel}
		aria-describedby={tooltipId}
		aria-controls={tooltipId}
		aria-expanded={isVisible}
		onfocus={focusTooltip}
		onblur={blurTooltip}
		onmouseenter={hoverTooltip}
		onmouseleave={leaveTooltip}
		onpointerdown={capturePointerToggleTarget}
		onclick={toggleTooltip}
		onkeydown={dismissOnEscape}
	>
		?
	</button>
	<span
		id={tooltipId}
		role="tooltip"
		hidden={!isVisible}
		class="absolute left-1/2 top-full z-20 mt-2 w-64 -translate-x-1/2 rounded-md border border-flapjack-ink/15 bg-flapjack-ink px-3 py-2 text-left text-xs font-medium text-white shadow-lg"
	>
		{message}
	</span>
</span>
