/**
 * Full - Console daily usage chart
 *
 * Red proof for the dashboard usage chart label-overlap boundary.
 */

import { test, expect, type SvgTextBox } from '../../fixtures/fixtures';

type LabelBox = SvgTextBox;

type LabelOverlap = {
	first: LabelBox;
	second: LabelBox;
	intersection: {
		width: number;
		height: number;
	};
};

function hasPositiveIntersection(first: LabelBox, second: LabelBox): boolean {
	const width = Math.min(first.right, second.right) - Math.max(first.left, second.left);
	const height = Math.min(first.bottom, second.bottom) - Math.max(first.top, second.top);
	return width > 0 && height > 0;
}

function describeOverlap(first: LabelBox, second: LabelBox): LabelOverlap {
	return {
		first,
		second,
		intersection: {
			width: Math.min(first.right, second.right) - Math.max(first.left, second.left),
			height: Math.min(first.bottom, second.bottom) - Math.max(first.top, second.top)
		}
	};
}

function findPositiveAreaOverlaps(labels: LabelBox[]): LabelOverlap[] {
	const overlaps: LabelOverlap[] = [];
	for (let firstIndex = 0; firstIndex < labels.length; firstIndex += 1) {
		for (let secondIndex = firstIndex + 1; secondIndex < labels.length; secondIndex += 1) {
			const first = labels[firstIndex];
			const second = labels[secondIndex];
			if (hasPositiveIntersection(first, second)) {
				overlaps.push(describeOverlap(first, second));
			}
		}
	}
	return overlaps;
}

function fixtureLabelBox(overrides: Partial<LabelBox>): LabelBox {
	return {
		index: 0,
		text: 'fixture',
		left: 0,
		top: 0,
		right: 10,
		bottom: 10,
		width: 10,
		height: 10,
		...overrides
	};
}

test.describe('Console daily usage chart', () => {
	test('row 6 @p0_coverage daily usage chart labels do not overlap at dashboard breakpoints', async ({
		page,
		seedDashboardUsage,
		readVisibleSvgTextBoxes
	}) => {
		test.setTimeout(120_000);

		expect(
			hasPositiveIntersection(
				fixtureLabelBox({ right: 10 }),
				fixtureLabelBox({ left: 10, right: 20 })
			)
		).toBe(false);
		expect(
			hasPositiveIntersection(fixtureLabelBox({}), fixtureLabelBox({ left: 9, right: 19 }))
		).toBe(true);

		const { month } = await seedDashboardUsage(`usage-chart-${Date.now()}`);

		for (const viewport of [
			{ width: 768, height: 900 },
			{ width: 1280, height: 900 }
		]) {
			await page.setViewportSize(viewport);
			await page.goto(`/console?month=${month}`);

			const usageChart = page.getByTestId('usage-chart');
			await expect(usageChart, `usage chart is absent at ${viewport.width}px`).toBeVisible({
				timeout: 90_000
			});

			const chartSvgs = usageChart.locator('svg');
			await expect(chartSvgs, `usage chart has no SVG at ${viewport.width}px`).not.toHaveCount(0);

			const labels = await readVisibleSvgTextBoxes(chartSvgs);

			expect(
				labels.length,
				`usage chart has no positive-area SVG labels at ${viewport.width}px`
			).toBeGreaterThan(0);

			const indeterminateLabels = labels.filter((box) =>
				[box.left, box.top, box.right, box.bottom, box.width, box.height].some(
					(value) => !Number.isFinite(value)
				)
			);
			expect(
				indeterminateLabels,
				`usage chart labels have indeterminate coordinates at ${viewport.width}px`
			).toEqual([]);

			const overlaps = findPositiveAreaOverlaps(labels);
			expect(
				overlaps,
				`usage chart labels overlap with positive area at ${viewport.width}px:\n${JSON.stringify(
					overlaps,
					null,
					2
				)}`
			).toEqual([]);
		}
	});
});
