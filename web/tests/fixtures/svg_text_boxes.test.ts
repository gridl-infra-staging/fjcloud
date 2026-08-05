import { describe, expect, it } from 'vitest';
import { __fixtureTestSeams } from './fixtures';

describe('SVG text box fixture seam', () => {
	it('returns finite positive-area boxes for visible SVG text nodes only', () => {
		const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
		const visibleLabel = document.createElementNS('http://www.w3.org/2000/svg', 'text');
		visibleLabel.textContent = 'Aug 04';
		Object.defineProperty(visibleLabel, 'getBoundingClientRect', {
			value: () =>
				({
					left: 10,
					top: 20,
					right: 58,
					bottom: 36,
					width: 48,
					height: 16
				}) as DOMRect
		});

		const emptyLabel = document.createElementNS('http://www.w3.org/2000/svg', 'text');
		emptyLabel.textContent = '   ';
		Object.defineProperty(emptyLabel, 'getBoundingClientRect', {
			value: () =>
				({
					left: 1,
					top: 1,
					right: 2,
					bottom: 2,
					width: 1,
					height: 1
				}) as DOMRect
		});

		const zeroAreaLabel = document.createElementNS('http://www.w3.org/2000/svg', 'text');
		zeroAreaLabel.textContent = 'hidden';
		Object.defineProperty(zeroAreaLabel, 'getBoundingClientRect', {
			value: () =>
				({
					left: 0,
					top: 0,
					right: 0,
					bottom: 0,
					width: 0,
					height: 0
				}) as DOMRect
		});

		svg.append(visibleLabel, emptyLabel, zeroAreaLabel);

		expect(__fixtureTestSeams.extractVisibleSvgTextBoxes([svg])).toEqual([
			{
				index: 0,
				text: 'Aug 04',
				left: 10,
				top: 20,
				right: 58,
				bottom: 36,
				width: 48,
				height: 16
			}
		]);
	});
});
