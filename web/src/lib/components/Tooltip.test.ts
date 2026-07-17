import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import Tooltip from './Tooltip.svelte';

afterEach(() => {
	cleanup();
});

describe('Tooltip', () => {
	it('uses explicit id bases with hidden role output by default', () => {
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'Available once your index is provisioned',
			idBase: 'overview-data-management-unavailable'
		});

		const trigger = screen.getByRole('button', {
			name: 'Why data management is unavailable'
		});
		const tooltip = screen.getByRole('tooltip', { hidden: true });

		expect(trigger).toHaveAttribute('id', 'tooltip-trigger-overview-data-management-unavailable');
		expect(tooltip).toHaveAttribute('id', 'tooltip-surface-overview-data-management-unavailable');
		expect(trigger).toHaveAttribute('aria-describedby', tooltip.id);
		expect(trigger).toHaveAttribute('aria-controls', tooltip.id);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).toHaveTextContent('Available once your index is provisioned');
		expect(tooltip).not.toBeVisible();
	});

	it('generates unique default ids for repeated trigger labels', () => {
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'First unavailable explanation'
		});
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'Second unavailable explanation'
		});

		const triggers = screen.getAllByRole('button', {
			name: 'Why data management is unavailable'
		});
		const tooltips = screen.getAllByRole('tooltip', { hidden: true });
		const triggerIds = triggers.map((trigger) => trigger.id);
		const tooltipIds = tooltips.map((tooltip) => tooltip.id);

		expect(new Set(triggerIds).size).toBe(2);
		expect(new Set(tooltipIds).size).toBe(2);
		expect(triggers[0]).toHaveAttribute('aria-describedby', tooltips[0].id);
		expect(triggers[1]).toHaveAttribute('aria-describedby', tooltips[1].id);
		expect(triggers[0]).toHaveAttribute('aria-controls', tooltips[0].id);
		expect(triggers[1]).toHaveAttribute('aria-controls', tooltips[1].id);
	});

	it('reveals and hides on focus and hover without consumer-managed state', async () => {
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'Available once your index is provisioned'
		});

		const trigger = screen.getByRole('button', {
			name: 'Why data management is unavailable'
		});
		const tooltip = screen.getByRole('tooltip', { hidden: true });

		await fireEvent.focus(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'true');
		expect(tooltip).toBeVisible();

		await fireEvent.blur(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();

		await fireEvent.mouseEnter(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'true');
		expect(tooltip).toBeVisible();

		await fireEvent.mouseLeave(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();
	});

	it('stays visible while focus or hover is still active', async () => {
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'Available once your index is provisioned'
		});

		const trigger = screen.getByRole('button', {
			name: 'Why data management is unavailable'
		});
		const tooltip = screen.getByRole('tooltip', { hidden: true });

		await fireEvent.focus(trigger);
		await fireEvent.mouseEnter(trigger);
		await fireEvent.mouseLeave(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'true');
		expect(tooltip).toBeVisible();

		await fireEvent.blur(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();

		await fireEvent.mouseEnter(trigger);
		await fireEvent.focus(trigger);
		await fireEvent.blur(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'true');
		expect(tooltip).toBeVisible();

		await fireEvent.mouseLeave(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();
	});

	it('dismisses with Escape and toggles by click for tap-style interaction', async () => {
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'Available once your index is provisioned'
		});

		const trigger = screen.getByRole('button', {
			name: 'Why data management is unavailable'
		});
		const tooltip = screen.getByRole('tooltip', { hidden: true });

		await fireEvent.click(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'true');
		expect(tooltip).toBeVisible();

		await fireEvent.keyDown(trigger, { key: 'Escape' });
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();

		await fireEvent.click(trigger);
		expect(tooltip).toBeVisible();

		await fireEvent.click(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();
	});

	it('lets click dismissal hide the tooltip while the trigger remains focused', async () => {
		render(Tooltip, {
			triggerLabel: 'Why data management is unavailable',
			message: 'Available once your index is provisioned'
		});

		const trigger = screen.getByRole('button', {
			name: 'Why data management is unavailable'
		});
		const tooltip = screen.getByRole('tooltip', { hidden: true });

		await fireEvent.pointerDown(trigger);
		await fireEvent.focus(trigger);
		await fireEvent.click(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'true');
		expect(tooltip).toBeVisible();

		await fireEvent.pointerDown(trigger);
		await fireEvent.click(trigger);
		expect(trigger).toHaveAttribute('aria-expanded', 'false');
		expect(tooltip).not.toBeVisible();
	});
});
