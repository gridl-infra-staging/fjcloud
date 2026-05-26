import { describe, it, expect, vi, beforeEach } from 'vitest';

const browserState = vi.hoisted(() => ({ value: false }));

vi.mock('$app/environment', () => ({
	get browser() {
		return browserState.value;
	}
}));

import { writeTextToClipboard } from './clipboard';

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
