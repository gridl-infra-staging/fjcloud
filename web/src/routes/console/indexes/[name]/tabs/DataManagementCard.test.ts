import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within, waitFor } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

const { collectOverviewExportRecordsMock, toastSuccessMock } = vi.hoisted(() => ({
	collectOverviewExportRecordsMock: vi.fn(),
	toastSuccessMock: vi.fn()
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} }),
	deserialize: vi.fn(),
	applyAction: vi.fn()
}));

vi.mock('./overview_export', async () => {
	const actual = await vi.importActual<typeof import('./overview_export')>('./overview_export');
	return {
		...actual,
		collectOverviewExportRecords: collectOverviewExportRecordsMock
	};
});

vi.mock('$lib/toast', async () => {
	const { TOAST_DURATION_MS } =
		await vi.importActual<typeof import('$lib/toast_contract')>('$lib/toast_contract');
	return {
		TOAST_DURATION_MS,
		toast: {
			success: toastSuccessMock
		}
	};
});

import DataManagementCard from './DataManagementCard.svelte';
import { sampleIndex } from '../detail.test.shared';
import type { Index } from '$lib/api/types';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

const ORIGINAL_ANCHOR_CLICK = HTMLAnchorElement.prototype.click;
const ORIGINAL_CREATE_OBJECT_URL = URL.createObjectURL;
const ORIGINAL_REVOKE_OBJECT_URL = URL.revokeObjectURL;

function restoreDownloadBrowserGlobals(): void {
	HTMLAnchorElement.prototype.click = ORIGINAL_ANCHOR_CLICK;
	Object.defineProperty(URL, 'createObjectURL', {
		value: ORIGINAL_CREATE_OBJECT_URL,
		configurable: true
	});
	Object.defineProperty(URL, 'revokeObjectURL', {
		value: ORIGINAL_REVOKE_OBJECT_URL,
		configurable: true
	});
}

function requireCapturedBlob(blob: Blob | null): Blob {
	expect(blob).not.toBeNull();
	if (blob === null) {
		throw new Error('Expected export to create a Blob');
	}
	return blob;
}

afterEach(() => {
	cleanup();
	collectOverviewExportRecordsMock.mockReset();
	vi.clearAllMocks();
	vi.useRealTimers();
	restoreDownloadBrowserGlobals();
});

describe('DataManagementCard', () => {
	it('renders the current button labels and upload action wiring', () => {
		const { container } = render(DataManagementCard, {
			index: sampleIndex,
			documentsUploadError: ''
		});

		const card = screen.getByTestId('overview-data-management');
		expect(within(card).getByTestId('overview-export-btn')).toHaveTextContent('Export Index');
		expect(within(card).getByTestId('overview-import-btn')).toHaveTextContent('Import Documents');
		expect(card).toHaveTextContent(
			'Export downloads all documents as JSON. Import adds new documents without replacing existing ones.'
		);

		const uploadForm = container.querySelector('form[action="?/uploadDocuments"]');
		expect(uploadForm).not.toBeNull();
		expect(uploadForm?.querySelector('input[type="hidden"][name="query"]')).toHaveAttribute(
			'value',
			''
		);
		expect(uploadForm?.querySelector('input[type="hidden"][name="hitsPerPage"]')).toHaveAttribute(
			'value',
			'20'
		);
	});

	it('keeps controls disabled and shows provisioning copy when endpoint is not ready', () => {
		const provisioningIndex: Index = { ...sampleIndex, endpoint: null, status: 'provisioning' };

		render(DataManagementCard, {
			index: provisioningIndex,
			documentsUploadError: ''
		});

		const card = screen.getByTestId('overview-data-management');
		const exportButton = within(card).getByTestId('overview-export-btn');
		const importButton = within(card).getByTestId('overview-import-btn');
		expect(exportButton).toBeDisabled();
		expect(importButton).toBeDisabled();
		expect(card).toHaveTextContent('Available once your index is provisioned');
		// L4 migrated the native title= attribute into a Tooltip SSOT; assert the
		// Tooltip trigger button is present (the message is in the surface, not on
		// the disabled buttons themselves).
		expect(
			within(card).getByRole('button', { name: 'Why data management is unavailable' })
		).toBeInTheDocument();
	});

	it('does not browse and shows a doc-count-aware limit alert when entries exceed 10k', async () => {
		const tooLargeIndex: Index = { ...sampleIndex, entries: 10001 };
		render(DataManagementCard, {
			index: tooLargeIndex,
			documentsUploadError: ''
		});

		await fireEvent.click(screen.getByTestId('overview-export-btn'));
		expect(collectOverviewExportRecordsMock).not.toHaveBeenCalled();
		expect(
			screen.getByRole('alert', {
				name: /overview-export-import-alert/i
			})
		).toHaveTextContent(
			'This index has 10,001 documents. Browser-side export is limited to 10,000 documents. Contact support to export larger indexes.'
		);
	});

	it('shows export progress and emits one shared success toast when export completes', async () => {
		let capturedExportBlob: Blob | null = null;
		const capturedDownloadFilenames: string[] = [];
		HTMLAnchorElement.prototype.click = function clickMock(this: HTMLAnchorElement): void {
			capturedDownloadFilenames.push(this.download);
		};
		const createObjectUrlSpy = vi.fn((blob: Blob) => {
			capturedExportBlob = blob;
			return 'blob:overview-export';
		});
		const revokeObjectUrlSpy = vi.fn();
		Object.defineProperty(URL, 'createObjectURL', {
			value: createObjectUrlSpy,
			configurable: true
		});
		Object.defineProperty(URL, 'revokeObjectURL', {
			value: revokeObjectUrlSpy,
			configurable: true
		});
		let resolveExport!: (records: Record<string, unknown>[]) => void;
		const exportCompletion = new Promise<Record<string, unknown>[]>((resolve) => {
			resolveExport = resolve;
		});
		collectOverviewExportRecordsMock.mockImplementation(({ onProgress }) => {
			onProgress?.({ exportedCount: 1500, totalDocuments: 1500 });
			return exportCompletion;
		});

		render(DataManagementCard, {
			index: sampleIndex,
			documentsUploadError: ''
		});

		const exportButton = screen.getByTestId('overview-export-btn');
		await fireEvent.click(exportButton);

		expect(exportButton).toHaveTextContent('Exporting 1,500 of 1,500 docs…');
		resolveExport([{ objectID: 'doc-1' }, { objectID: 'doc-2' }]);
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Exported 2 documents.', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByText('Exported 2 documents')).not.toBeInTheDocument();

		const expectedDayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
		expect(capturedDownloadFilenames).toEqual([
			`${sampleIndex.name}-export-${expectedDayStamp}.json`
		]);
		const exportBlob = requireCapturedBlob(capturedExportBlob);
		const exportedJson = JSON.parse(await exportBlob.text()) as Array<{
			objectID: string;
		}>;
		expect(exportedJson).toEqual([{ objectID: 'doc-1' }, { objectID: 'doc-2' }]);

		expect(createObjectUrlSpy).toHaveBeenCalledTimes(1);
		await waitFor(() => {
			expect(revokeObjectUrlSpy).toHaveBeenCalledTimes(1);
		});
	});

	it('sanitizes user-controlled index names before assigning the download filename', async () => {
		let capturedDownloadFilename = '';
		HTMLAnchorElement.prototype.click = function clickMock(this: HTMLAnchorElement): void {
			capturedDownloadFilename = this.download;
		};
		Object.defineProperty(URL, 'createObjectURL', {
			value: vi.fn(() => 'blob:overview-export'),
			configurable: true
		});
		const revokeObjectUrlSpy = vi.fn();
		Object.defineProperty(URL, 'revokeObjectURL', {
			value: revokeObjectUrlSpy,
			configurable: true
		});
		collectOverviewExportRecordsMock.mockResolvedValue([{ objectID: 'doc-1' }]);
		const oddNameIndex: Index = {
			...sampleIndex,
			name: '../quarterly exports\\north america\r\n'
		};

		render(DataManagementCard, {
			index: oddNameIndex,
			documentsUploadError: ''
		});

		await fireEvent.click(screen.getByTestId('overview-export-btn'));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Exported 1 document.', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(screen.queryByText('Exported 1 document')).not.toBeInTheDocument();

		const expectedDayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
		expect(capturedDownloadFilename).toBe(
			`quarterly_exports_north_america-export-${expectedDayStamp}.json`
		);
		await waitFor(() => {
			expect(revokeObjectUrlSpy).toHaveBeenCalledTimes(1);
		});
	});

	it('keeps zero-entry exports downloadable while preserving filename and toast contracts', async () => {
		vi.useFakeTimers();
		let capturedExportBlob: Blob | null = null;
		const capturedDownloadFilenames: string[] = [];
		HTMLAnchorElement.prototype.click = function clickMock(this: HTMLAnchorElement): void {
			capturedDownloadFilenames.push(this.download);
		};
		const createObjectUrlSpy = vi.fn((blob: Blob) => {
			capturedExportBlob = blob;
			return 'blob:zero-entry-overview-export';
		});
		const revokeObjectUrlSpy = vi.fn();
		Object.defineProperty(URL, 'createObjectURL', {
			value: createObjectUrlSpy,
			configurable: true
		});
		Object.defineProperty(URL, 'revokeObjectURL', {
			value: revokeObjectUrlSpy,
			configurable: true
		});
		collectOverviewExportRecordsMock.mockResolvedValue([]);
		const emptyIndex: Index = {
			...sampleIndex,
			name: '../empty launch index',
			entries: 0
		};

		render(DataManagementCard, {
			index: emptyIndex,
			documentsUploadError: ''
		});

		await fireEvent.click(screen.getByTestId('overview-export-btn'));
		await Promise.resolve();
		await Promise.resolve();
		expect(toastSuccessMock).toHaveBeenCalledWith('Exported 0 documents.', {
			duration: TOAST_DURATION_MS
		});

		const expectedDayStamp = new Date().toISOString().slice(0, 10).replace(/-/g, '');
		expect(capturedDownloadFilenames).toEqual([
			`empty_launch_index-export-${expectedDayStamp}.json`
		]);
		expect(createObjectUrlSpy).toHaveBeenCalledTimes(1);
		const exportBlob = requireCapturedBlob(capturedExportBlob);
		expect(exportBlob.type).toBe('application/json');
		expect(await exportBlob.text()).toBe('[]');
		expect(revokeObjectUrlSpy).not.toHaveBeenCalled();
		await vi.advanceTimersToNextTimerAsync();
		expect(revokeObjectUrlSpy).toHaveBeenCalledWith('blob:zero-entry-overview-export');
		expect(revokeObjectUrlSpy).toHaveBeenCalledTimes(1);
	});

	it('shows export failure copy with partial progress context and avoids partial downloads', async () => {
		const createObjectUrlSpy = vi.fn(() => 'blob:overview-export');
		const revokeObjectUrlSpy = vi.fn();
		Object.defineProperty(URL, 'createObjectURL', {
			value: createObjectUrlSpy,
			configurable: true
		});
		Object.defineProperty(URL, 'revokeObjectURL', {
			value: revokeObjectUrlSpy,
			configurable: true
		});
		collectOverviewExportRecordsMock.mockRejectedValue(
			new Error('Export failed after 600/1500 documents: upstream request timed out')
		);
		render(DataManagementCard, {
			index: sampleIndex,
			documentsUploadError: ''
		});

		await fireEvent.click(screen.getByTestId('overview-export-btn'));
		await waitFor(() => {
			expect(
				screen.getByRole('alert', {
					name: /overview-export-import-alert/i
				})
			).toHaveTextContent('Export failed after 600/1500 documents: upstream request timed out');
		});
		expect(createObjectUrlSpy).not.toHaveBeenCalled();
		expect(revokeObjectUrlSpy).not.toHaveBeenCalled();
	});

	it('uses Uploading… label and preserves json/csv import file handling', async () => {
		const { container } = render(DataManagementCard, {
			index: sampleIndex,
			documentsUploadError: ''
		});
		const uploadForm = container.querySelector(
			'form[action="?/uploadDocuments"]'
		) as HTMLFormElement | null;
		expect(uploadForm).not.toBeNull();
		const requestSubmitSpy = vi.fn();
		if (uploadForm) {
			uploadForm.requestSubmit = requestSubmitSpy;
		}

		const importFileInput = screen.getByLabelText(/import json or csv file/i) as HTMLInputElement;
		expect(importFileInput.accept).toContain('.json');
		expect(importFileInput.accept).toContain('.csv');

		const validJsonFile = new File(
			['[{"objectID":"doc-1"},{"objectID":"doc-2"}]'],
			'records.json',
			{
				type: 'application/json'
			}
		);
		const validCsvFile = new File(['objectID,title\ndoc-3,Three'], 'records.csv', {
			type: 'text/csv'
		});
		await fireEvent.change(importFileInput, { target: { files: [validJsonFile] } });
		await fireEvent.change(importFileInput, { target: { files: [validCsvFile] } });

		await waitFor(() => {
			expect(requestSubmitSpy).toHaveBeenCalledTimes(2);
		});
		expect(screen.getByTestId('overview-import-btn')).toHaveTextContent('Uploading…');
	});

	it('surfaces parse failures from parseUploadFileRecords as inline alerts', async () => {
		render(DataManagementCard, {
			index: sampleIndex,
			documentsUploadError: ''
		});

		const importFileInput = screen.getByLabelText(/import json or csv file/i);
		const unsupportedFile = new File(['bad format'], 'payload.txt', { type: 'text/plain' });
		await fireEvent.change(importFileInput, { target: { files: [unsupportedFile] } });

		await waitFor(() => {
			expect(
				screen.getByRole('alert', {
					name: /overview-export-import-alert/i
				})
			).toHaveTextContent('Only .json and .csv files are supported');
		});
	});
});
