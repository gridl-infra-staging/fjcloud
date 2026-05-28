import { beforeEach, describe, expect, it, vi } from 'vitest';
import { makeActionArgs } from './detail.server.test.shared';

const { saveQsConfigActionMock, deleteQsConfigActionMock, rebuildQsConfigActionMock } = vi.hoisted(
	() => ({
		saveQsConfigActionMock: vi.fn(),
		deleteQsConfigActionMock: vi.fn(),
		rebuildQsConfigActionMock: vi.fn()
	})
);

vi.mock('./suggestions-management.server', () => ({
	saveQsConfigAction: saveQsConfigActionMock,
	deleteQsConfigAction: deleteQsConfigActionMock,
	rebuildQsConfigAction: rebuildQsConfigActionMock
}));

import { actions } from './+page.server';

describe('Index detail page server -- actions (suggestions seam ownership)', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('saveQsConfig action delegates to suggestions-management owner', async () => {
		saveQsConfigActionMock.mockResolvedValue({ qsConfigSaved: true });

		const formData = new FormData();
		formData.set('config', JSON.stringify({ indexName: 'products' }));

		const result = await actions.saveQsConfig(makeActionArgs('saveQsConfig', formData) as never);

		expect(saveQsConfigActionMock).toHaveBeenCalledWith({
			request: expect.any(Request),
			indexName: 'products',
			token: 'jwt-token'
		});
		expect(result).toEqual({ qsConfigSaved: true });
	});

	it('saveQsConfig action surfaces owner errors without mutating payload', async () => {
		saveQsConfigActionMock.mockRejectedValue(new Error('suggestions save failed'));

		const formData = new FormData();
		formData.set('config', JSON.stringify({ indexName: 'products' }));

		await expect(
			actions.saveQsConfig(makeActionArgs('saveQsConfig', formData) as never)
		).rejects.toThrow('suggestions save failed');
		expect(saveQsConfigActionMock).toHaveBeenCalledWith({
			request: expect.any(Request),
			indexName: 'products',
			token: 'jwt-token'
		});
	});

	it('deleteQsConfig action delegates to suggestions-management owner', async () => {
		deleteQsConfigActionMock.mockResolvedValue({ qsConfigDeleted: true });

		const result = await actions.deleteQsConfig(
			makeActionArgs('deleteQsConfig', new FormData()) as never
		);

		expect(deleteQsConfigActionMock).toHaveBeenCalledWith({
			indexName: 'products',
			token: 'jwt-token'
		});
		expect(result).toEqual({ qsConfigDeleted: true });
	});

	it('deleteQsConfig action surfaces owner errors without mutating payload', async () => {
		deleteQsConfigActionMock.mockRejectedValue(new Error('suggestions delete failed'));

		await expect(
			actions.deleteQsConfig(makeActionArgs('deleteQsConfig', new FormData()) as never)
		).rejects.toThrow('suggestions delete failed');
		expect(deleteQsConfigActionMock).toHaveBeenCalledWith({
			indexName: 'products',
			token: 'jwt-token'
		});
	});

	it('rebuildQsConfig action delegates to suggestions-management owner', async () => {
		rebuildQsConfigActionMock.mockResolvedValue({ qsBuildQueued: true });

		const result = await actions.rebuildQsConfig(
			makeActionArgs('rebuildQsConfig', new FormData()) as never
		);

		expect(rebuildQsConfigActionMock).toHaveBeenCalledWith({
			indexName: 'products',
			token: 'jwt-token'
		});
		expect(result).toEqual({ qsBuildQueued: true });
	});

	it('rebuildQsConfig action surfaces owner errors without mutating payload', async () => {
		rebuildQsConfigActionMock.mockRejectedValue(new Error('rebuild backend unavailable'));

		await expect(
			actions.rebuildQsConfig(makeActionArgs('rebuildQsConfig', new FormData()) as never)
		).rejects.toThrow('rebuild backend unavailable');
		expect(rebuildQsConfigActionMock).toHaveBeenCalledWith({
			indexName: 'products',
			token: 'jwt-token'
		});
	});
});
