import { afterEach, describe, expect, it } from 'vitest';

import { expectVisibleWarningGroupsInOrder } from './warning_presentation_test_support';

afterEach(() => document.body.replaceChildren());

describe('compatibility warning group test oracle', () => {
	it('allows visible warning-group headings with separately named semantic lists', () => {
		const region = document.createElement('section');
		region.innerHTML = `
			<h3>index settings</h3>
			<ul aria-label="index settings compatibility warnings 1">
				<li>Adjust setting</li>
			</ul>
		`;
		document.body.appendChild(region);

		expectVisibleWarningGroupsInOrder(region, [
			{
				resourceLabel: 'index settings',
				accessibleName: 'index settings compatibility warnings 1'
			}
		]);
	});

	it('binds warning-group heading order to each exact semantic list', () => {
		const region = document.createElement('section');
		region.innerHTML = `
			<h3>rules</h3>
			<ul aria-label="synonyms compatibility warnings">
				<li>Change synonym</li>
			</ul>
			<h3>synonyms</h3>
			<ul aria-label="rules compatibility warnings">
				<li>Rewrite rule</li>
			</ul>
		`;
		document.body.appendChild(region);

		expect(() =>
			expectVisibleWarningGroupsInOrder(region, [
				{
					resourceLabel: 'synonyms',
					accessibleName: 'synonyms compatibility warnings'
				},
				{
					resourceLabel: 'rules',
					accessibleName: 'rules compatibility warnings'
				}
			])
		).toThrow(/visible heading/);
	});
});
