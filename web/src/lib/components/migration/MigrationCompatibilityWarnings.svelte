<script lang="ts">
	import type { AlgoliaImportCompatibilityWarningPresentation } from './job_presentation';

	// Sole renderer for migration compatibility warnings. Every producer of the
	// presentation type renders through this component so an unchanged finding
	// cannot look different depending on where it is shown.
	let {
		presentation
	}: {
		presentation: AlgoliaImportCompatibilityWarningPresentation | null;
	} = $props();

	// Scoped per instance so the labelling id stays unique if more than one
	// warning region is ever mounted on a page.
	const componentId = $props.id();
	const titleId = `${componentId}-warning-title`;

	function warningListAccessibleName(resourceLabel: string, groupIndex: number): string {
		const matchingGroups =
			presentation?.groups.filter((group) => group.resourceLabel === resourceLabel) ?? [];
		if (matchingGroups.length <= 1) {
			return `${resourceLabel} compatibility warnings`;
		}
		const duplicateIndex =
			matchingGroups.findIndex((group) => group === presentation?.groups[groupIndex]) + 1;
		return `${resourceLabel} compatibility warnings ${duplicateIndex}`;
	}
</script>

{#if presentation}
	<div class="space-y-3 rounded border border-flapjack-yellow/50 p-3 text-sm text-flapjack-ink">
		<p data-testid="migration-job-warning-summary">
			{presentation.summary}
		</p>
		<section aria-labelledby={titleId} class="space-y-3">
			<h4 id={titleId} class="text-sm font-semibold text-flapjack-ink">Compatibility warnings</h4>
			{#each presentation.groups as group, groupIndex (group.resource)}
				<div class="space-y-2">
					<h5 class="text-sm font-medium text-flapjack-ink">{group.resourceLabel}</h5>
					<ul
						class="space-y-2"
						aria-label={warningListAccessibleName(group.resourceLabel, groupIndex)}
					>
						{#each group.warnings as warning, warningIndex (`${group.resource}-${warningIndex}`)}
							<li class="space-y-1 break-words">
								<p data-testid="migration-warning-message">{warning.message}</p>
								{#if warning.severity}
									<p
										data-testid="migration-warning-severity"
										class="text-xs font-medium text-flapjack-ink/70"
									>
										{warning.severity}
									</p>
								{/if}
								<p data-testid="migration-warning-code" class="text-xs text-flapjack-ink/70">
									{warning.code}
								</p>
								{#if warning.locator}
									<p data-testid="migration-warning-locator" class="text-xs text-flapjack-ink/70">
										{warning.locator}
									</p>
								{/if}
							</li>
						{/each}
					</ul>
				</div>
			{/each}
		</section>
	</div>
{/if}
