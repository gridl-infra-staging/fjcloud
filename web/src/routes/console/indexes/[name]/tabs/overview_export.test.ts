import { describe, it, expect, vi } from 'vitest';

import { collectOverviewExportRecords, EXPORT_ENTRY_LIMIT } from './overview_export';

describe('collectOverviewExportRecords', () => {
	it('returns an empty payload without browsing when the index has zero entries', async () => {
		const browseSpy = vi.fn();

		const records = await collectOverviewExportRecords({
			indexEntries: 0,
			requestBrowsePage: browseSpy
		});

		expect(records).toEqual([]);
		expect(browseSpy).not.toHaveBeenCalled();
	});

	it('short-circuits with the hard-cap message when entry count exceeds limit', async () => {
		await expect(
			collectOverviewExportRecords({
				indexEntries: EXPORT_ENTRY_LIMIT + 1,
				requestBrowsePage: vi.fn()
			})
		).rejects.toThrow('Export is limited to indexes with 10,000 entries or fewer');
	});

	it('walks browse cursors across multiple pages and returns all hits', async () => {
		const progressSpy = vi.fn();
		const browseSpy = vi
			.fn()
			.mockResolvedValueOnce({
				type: 'success',
				data: {
					documents: {
						hits: [{ objectID: 'doc-1' }],
						cursor: 'cursor-2'
					}
				}
			})
			.mockResolvedValueOnce({
				type: 'success',
				data: {
					documents: {
						hits: [{ objectID: 'doc-2' }, { objectID: 'doc-3' }],
						cursor: null
					}
				}
			});

		const records = await collectOverviewExportRecords({
			indexEntries: 3,
			requestBrowsePage: browseSpy,
			onProgress: progressSpy
		});

		expect(browseSpy).toHaveBeenCalledTimes(2);
		expect(browseSpy).toHaveBeenNthCalledWith(1, null);
		expect(browseSpy).toHaveBeenNthCalledWith(2, 'cursor-2');
		expect(progressSpy).toHaveBeenNthCalledWith(1, { exportedCount: 1, totalDocuments: 3 });
		expect(progressSpy).toHaveBeenNthCalledWith(2, { exportedCount: 3, totalDocuments: 3 });
		expect(records).toEqual([{ objectID: 'doc-1' }, { objectID: 'doc-2' }, { objectID: 'doc-3' }]);
	});

	it('treats empty-string cursor as terminal and stops pagination after first page', async () => {
		const browseSpy = vi.fn().mockResolvedValueOnce({
			type: 'success',
			data: {
				documents: {
					hits: [{ objectID: 'doc-1' }],
					cursor: ''
				}
			}
		});

		const records = await collectOverviewExportRecords({
			indexEntries: 1,
			requestBrowsePage: browseSpy
		});

		expect(browseSpy).toHaveBeenCalledTimes(1);
		expect(records).toEqual([{ objectID: 'doc-1' }]);
	});

	it('fails the export when a later browse page rejects', async () => {
		const browseSpy = vi
			.fn()
			.mockResolvedValueOnce({
				type: 'success',
				data: {
					documents: {
						hits: [{ objectID: 'doc-1' }],
						cursor: 'cursor-2'
					}
				}
			})
			.mockResolvedValueOnce({
				type: 'failure',
				data: {
					documentsBrowseError: 'browse upstream failed on page 2'
				}
			});

		await expect(
			collectOverviewExportRecords({
				indexEntries: 2,
				requestBrowsePage: browseSpy
			})
		).rejects.toThrow('Export failed after 1/2 documents: browse upstream failed on page 2');
		expect(browseSpy).toHaveBeenCalledTimes(2);
	});

	it('keeps all-or-nothing behavior by rejecting after partial progress', async () => {
		const progressSpy = vi.fn();
		const browseSpy = vi
			.fn()
			.mockResolvedValueOnce({
				type: 'success',
				data: {
					documents: {
						hits: [{ objectID: 'doc-1' }, { objectID: 'doc-2' }],
						cursor: 'cursor-2'
					}
				}
			})
			.mockRejectedValueOnce(new Error('upstream timeout'));

		await expect(
			collectOverviewExportRecords({
				indexEntries: 4,
				requestBrowsePage: browseSpy,
				onProgress: progressSpy
			})
		).rejects.toThrow('Export failed after 2/4 documents: upstream timeout');
		expect(progressSpy).toHaveBeenCalledTimes(1);
		expect(progressSpy).toHaveBeenNthCalledWith(1, { exportedCount: 2, totalDocuments: 4 });
	});
});
