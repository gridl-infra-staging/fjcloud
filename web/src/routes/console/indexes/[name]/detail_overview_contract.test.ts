import { describe, it, expect, afterEach } from 'vitest';
import { screen, waitFor, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import {
	createDeferred,
	invalidateAllMock,
	openTab,
	queueEnhanceResultData,
	renderPage,
	resetDetailPageTestState,
	setEnhanceUpdateHook,
	uploadOverviewImportFile
} from './detail_test_harness';
import type { DetailPageForm } from './detail_test_harness';
import { createMockPageData } from './detail.test.shared';

const TWO_DOCUMENTS_JSON =
	'[{"objectID":"doc-1","title":"One"},{"objectID":"doc-2","title":"Two"}]';
const THREE_DOCUMENTS_JSON =
	'[{"objectID":"doc-1","title":"One"},{"objectID":"doc-2","title":"Two"},{"objectID":"doc-3","title":"Three"}]';

afterEach(() => {
	resetDetailPageTestState();
});

describe('Index detail page — Overview route contract', () => {
	it('keeps route-level analytics navigation without duplicate setup footer', () => {
		renderPage();

		expect(screen.getByTestId('overview-view-analytics-link')).toHaveAttribute(
			'href',
			'/console/indexes/products?tab=analytics'
		);
		expect(screen.queryByTestId('overview-navigation')).not.toBeInTheDocument();
		expect(screen.queryByRole('heading', { name: 'Continue setup' })).not.toBeInTheDocument();
	});

	it('keeps the shell-owned import banner visible when refresh revalidation fails', async () => {
		invalidateAllMock.mockRejectedValueOnce(new Error('revalidation failed'));
		renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		const banner = await screen.findByTestId('overview-import-success-banner');
		expect(banner).toHaveTextContent('Imported 2 documents. Refresh page to see them');
		expect(
			within(screen.getByTestId('overview-data-management')).queryByText('Documents uploaded.')
		).not.toBeInTheDocument();
		const statsSection = screen.getByTestId('stats-section');
		expect(banner.compareDocumentPosition(statsSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBe(
			Node.DOCUMENT_POSITION_FOLLOWING
		);
		const refreshButton = screen.getByRole('button', { name: 'Refresh' });
		expect(refreshButton).toBeVisible();
		await fireEvent.click(refreshButton);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		expect(screen.getByTestId('overview-import-success-banner')).toHaveTextContent(
			'Imported 2 documents. Refresh page to see them'
		);
	});

	it('clears the shell-owned import banner only after refresh revalidation succeeds', async () => {
		invalidateAllMock.mockResolvedValueOnce(undefined);
		renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		const banner = await screen.findByTestId('overview-import-success-banner');
		expect(banner).toHaveTextContent('Imported 2 documents. Refresh page to see them');
		await fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		await waitFor(() => {
			expect(screen.queryByTestId('overview-import-success-banner')).not.toBeInTheDocument();
		});
	});

	it('does not show import success again during a new post-refresh import attempt before upload success returns', async () => {
		invalidateAllMock.mockResolvedValueOnce(undefined);
		renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		await screen.findByTestId('overview-import-success-banner');
		await fireEvent.click(screen.getByRole('button', { name: 'Refresh' }));
		await waitFor(() => {
			expect(screen.queryByTestId('overview-import-success-banner')).not.toBeInTheDocument();
		});
		const secondUploadActionResult = createDeferred();
		setEnhanceUpdateHook(() => secondUploadActionResult.promise);
		queueEnhanceResultData({ documentsUploadSuccess: true });
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		await screen.findByRole('button', { name: 'Uploading…' });
		expect(screen.queryByTestId('overview-import-success-banner')).not.toBeInTheDocument();
		secondUploadActionResult.resolve();
		await waitFor(() => {
			expect(screen.getByTestId('overview-import-success-banner')).toHaveTextContent(
				'Imported 2 documents. Refresh page to see them'
			);
		});
	});

	it('hides Refresh off-tab', async () => {
		renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		await screen.findByTestId('overview-import-success-banner');
		await openTab('Settings');
		expect(screen.queryByRole('button', { name: 'Refresh' })).not.toBeInTheDocument();
	});

	it('keeps the shell-owned import banner hidden during a second import attempt until that upload succeeds', async () => {
		renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		await screen.findByText('Imported 2 documents. Refresh page to see them');
		expect(
			within(screen.getByTestId('overview-data-management')).queryByRole('button', {
				name: 'Refresh'
			})
		).not.toBeInTheDocument();
		const secondUploadActionResult = createDeferred();
		setEnhanceUpdateHook(() => secondUploadActionResult.promise);
		queueEnhanceResultData({ documentsUploadSuccess: true });
		await uploadOverviewImportFile(THREE_DOCUMENTS_JSON, 'records-three.json');
		await screen.findByRole('button', { name: 'Uploading…' });
		expect(screen.queryByTestId('overview-import-success-banner')).not.toBeInTheDocument();
		secondUploadActionResult.resolve();
		await waitFor(() => {
			expect(screen.getByTestId('overview-import-success-banner')).toHaveTextContent(
				'Imported 3 documents. Refresh page to see them'
			);
		});
		expect(
			within(screen.getByTestId('overview-data-management')).queryByText('Documents uploaded.')
		).not.toBeInTheDocument();
	});

	it('keeps the last successful import banner visible when an unrelated overview action result replaces form data', async () => {
		const view = renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		await screen.findByText('Imported 2 documents. Refresh page to see them');
		await view.rerender({
			data: createMockPageData(),
			form: { documentsBrowseSuccess: true } as DetailPageForm
		});
		expect(screen.getByTestId('overview-import-success-banner')).toHaveTextContent(
			'Imported 2 documents. Refresh page to see them'
		);
		expect(screen.getByRole('button', { name: 'Refresh' })).toBeVisible();
	});

	it('restores the last successful import banner when a second upload fails before Refresh', async () => {
		const view = renderPage({}, { documentsUploadSuccess: true } as DetailPageForm);
		await uploadOverviewImportFile(TWO_DOCUMENTS_JSON, 'records.json');
		await screen.findByText('Imported 2 documents. Refresh page to see them');
		const failedUploadActionResult = createDeferred();
		setEnhanceUpdateHook(async () => {
			await failedUploadActionResult.promise;
			await view.rerender({
				data: createMockPageData(),
				form: { documentsUploadError: 'Upload failed' } as DetailPageForm
			});
		});
		queueEnhanceResultData({ documentsUploadError: 'Upload failed' });
		await uploadOverviewImportFile(THREE_DOCUMENTS_JSON, 'records-three.json');
		await screen.findByRole('button', { name: 'Uploading…' });
		expect(screen.queryByTestId('overview-import-success-banner')).not.toBeInTheDocument();
		failedUploadActionResult.resolve();
		await waitFor(() => {
			expect(screen.getByTestId('overview-import-success-banner')).toHaveTextContent(
				'Imported 2 documents. Refresh page to see them'
			);
		});
		expect(
			screen.getByRole('alert', {
				name: /overview-export-import-alert/i
			})
		).toHaveTextContent('Upload failed');
	});
});
