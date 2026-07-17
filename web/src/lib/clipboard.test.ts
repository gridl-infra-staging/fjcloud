import { describe, it, expect, vi, beforeEach } from 'vitest';

const browserState = vi.hoisted(() => ({ value: false }));

vi.mock('$app/environment', () => ({
	get browser() {
		return browserState.value;
	}
}));

import { copyToClipboard, writeTextToClipboard } from './clipboard';

describe('writeTextToClipboard', () => {
	beforeEach(() => {
		browserState.value = false;
		vi.unstubAllGlobals();
	});

	it('writes text in browser mode and returns success', async () => {
		browserState.value = true;
		const writeText = vi.fn().mockResolvedValue(undefined);
		vi.stubGlobal('navigator', { clipboard: { writeText } });

		const result = await writeTextToClipboard('hello');

		expect(result).toBe('success');
		expect(writeText).toHaveBeenCalledWith('hello');
	});

	it('returns unavailable in non-browser mode', async () => {
		const result = await writeTextToClipboard('hello');
		expect(result).toBe('unavailable');
	});

	it('returns failed when browser clipboard write throws', async () => {
		browserState.value = true;
		const writeText = vi.fn().mockRejectedValue(new Error('no permission'));
		vi.stubGlobal('navigator', { clipboard: { writeText } });

		const result = await writeTextToClipboard('hello');

		expect(result).toBe('failed');
		expect(writeText).toHaveBeenCalledWith('hello');
	});
});

describe('copyToClipboard', () => {
	beforeEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
		document.body.innerHTML = '';
	});

	it('writes text and temporarily swaps the trigger label on success', async () => {
		vi.useFakeTimers();
		const writeText = vi.fn().mockResolvedValue(undefined);
		vi.stubGlobal('navigator', { clipboard: { writeText } });
		const button = document.createElement('button');
		button.textContent = 'Copy example personalization strategy';
		document.body.append(button);

		const copied = await copyToClipboard('{"personalizationImpact":75}', button, 'Example copied');

		expect(copied).toBe(true);
		expect(writeText).toHaveBeenCalledWith('{"personalizationImpact":75}');
		expect(button).toHaveTextContent('Example copied');
		await vi.advanceTimersByTimeAsync(2000);
		expect(button).toHaveTextContent('Copy example personalization strategy');
	});

	it('reports unavailable clipboard access without changing the trigger label', async () => {
		vi.stubGlobal('navigator', {});
		const button = document.createElement('button');
		button.textContent = 'Copy example personalization strategy';

		const copied = await copyToClipboard('payload', button, 'Example copied');

		expect(copied).toBe(false);
		expect(button).toHaveTextContent('Copy example personalization strategy');
	});
});
