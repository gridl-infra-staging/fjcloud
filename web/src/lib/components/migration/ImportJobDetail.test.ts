import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/svelte';

import type { AlgoliaMigrationCapabilities, PublicAlgoliaImportJob } from '$lib/api/types';
import ImportJobDetail from './ImportJobDetail.svelte';
import {
	NON_TERMINAL_IMPORT_STATUSES,
	NO_MIGRATION_CAPABILITIES,
	publicImportJob
} from './migration_test_fixtures';
import {
	expectVisibleWarningGroupsInOrder,
	publicWarnings,
	WARNING_GROUPS
} from './warning_presentation_test_support';

afterEach(cleanup);
afterEach(() => vi.restoreAllMocks());

const CANCEL_CONFIRM_COPY =
	'Cancel this import? The import stops, partially-copied staging work is discarded, and the existing destination index is left exactly as it is.';
const RESUME_API_KEY_CANARY = 'resume-secret-key-canary-0007';

describe('Algolia import job detail presentation', () => {
	it('renders running phase copy, safe reload guidance, and stable job fields', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'copying_documents',
				updatedAt: '2026-07-18T10:06:00Z'
			}),
			reloading: true
		});

		expect(screen.getByRole('heading', { name: /products import/i })).toBeInTheDocument();
		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Copying documents');
		expect(screen.getByTestId('migration-job-phase')).toHaveTextContent('Copying records');
		expect(screen.getByTestId('migration-job-reloading')).toHaveTextContent('Refreshing status');
		expect(screen.getByRole('status')).toHaveTextContent('Refreshing status');
		expect(screen.getByTestId('migration-job-safe-reload')).toHaveTextContent(
			'You can leave or reload this page without stopping the import.'
		);
		expect(screen.getByTestId('migration-job-source')).toHaveTextContent('products');
		expect(screen.getByTestId('migration-job-destination')).toHaveTextContent(
			'products migrated/2026'
		);
		expect(screen.getByTestId('migration-job-updated')).toHaveTextContent('Jul 18, 2026');
	});

	it.each(NON_TERMINAL_IMPORT_STATUSES)(
		'keeps leave and reload guidance visible for backend phase %s',
		(status) => {
			render(ImportJobDetail, { job: publicImportJob({ status }) });

			expect(screen.getByTestId('migration-job-safe-reload')).toHaveTextContent(
				'You can leave or reload this page without stopping the import.'
			);
		}
	);

	it.each([...NON_TERMINAL_IMPORT_STATUSES, 'failed', 'cancelled', 'completed'] as const)(
		'hides terminal outcome rows without an observed outcome for status %s',
		(status) => {
			render(ImportJobDetail, { job: publicImportJob({ status, terminalOutcomeObserved: false }) });
			expect(screen.queryByTestId('migration-summary-settings')).not.toBeInTheDocument();
			expect(screen.queryByTestId('migration-summary-synonyms')).not.toBeInTheDocument();
			expect(screen.queryByTestId('migration-summary-rules')).not.toBeInTheDocument();
		}
	);

	it('keeps responsive action and field structures deterministic for narrow layouts', () => {
		render(ImportJobDetail, {
			job: publicImportJob({ status: 'copying_documents' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent: () => {}
		});

		const fields = screen.getByLabelText('Import fields');
		expect(fields).toHaveClass('grid');
		expect(fields).toHaveClass('gap-3');
		expect(fields).toHaveClass('sm:grid-cols-4');
		expect(screen.getByTestId('migration-job-capability-actions')).toHaveClass('flex-wrap');
		expect(screen.getByRole('button', { name: /cancel import/i })).toHaveTextContent(
			'Cancel import'
		);
	});

	it('renders observed completed facts and primary/secondary actions with encoded targets', () => {
		render(ImportJobDetail, { job: publicImportJob() });

		const documents = screen.getByTestId('migration-summary-documents');
		expect(documents).toHaveTextContent('13 imported');
		expect(documents).toHaveTextContent('17 expected');
		expect(documents).toHaveTextContent('4 rejected');
		expect(screen.getByTestId('migration-summary-settings')).toHaveTextContent('Applied');
		expect(screen.getByTestId('migration-summary-settings')).not.toHaveTextContent(
			/expected|rejected/
		);
		expect(screen.getByTestId('migration-summary-synonyms')).toHaveTextContent('3 imported');
		expect(screen.getByTestId('migration-summary-synonyms')).not.toHaveTextContent(
			/expected|rejected/
		);
		expect(screen.getByTestId('migration-summary-rules')).toHaveTextContent('6 imported');
		expect(screen.getByTestId('migration-summary-rules')).not.toHaveTextContent(
			/expected|rejected/
		);
		expect(screen.getByRole('link', { name: /test search/i })).toHaveAttribute(
			'href',
			'/console/indexes/products%20migrated%2F2026?tab=search'
		);
		expect(screen.getByRole('link', { name: /view index/i })).toHaveAttribute(
			'href',
			'/console/indexes/products%20migrated%2F2026'
		);
	});

	it.each([
		['not_started', 'The destination has not been promoted yet.'],
		['unchanged', 'The existing destination index is unchanged.'],
		['promoted', 'The destination index was promoted.'],
		[
			'unknown',
			'Destination safety is unproven. Reconcile the destination before retrying into this target.'
		]
	] as const)('renders backend publication disposition %s', (publicationDisposition, copy) => {
		render(ImportJobDetail, { job: publicImportJob({ publicationDisposition }) });

		expect(screen.getByTestId('migration-job-disposition')).toHaveTextContent(copy);
	});

	it('renders every compatibility warning in semantic bounded-label groups', () => {
		const credentialCanary = 'producer-credential-canary';
		const sourcePayloadCanary = 'producer-source-payload-canary';
		const warningGroups = WARNING_GROUPS;
		const warnings = publicWarnings(warningGroups);
		const { container } = render(ImportJobDetail, {
			job: publicImportJob({
				status: 'completed_with_warnings',
				warnings,
				producerCredentials: credentialCanary,
				sourcePayload: sourcePayloadCanary
			} as Partial<PublicAlgoliaImportJob> & {
				producerCredentials: string;
				sourcePayload: string;
			})
		});

		expect(screen.getByTestId('migration-job-warning-summary').textContent).toBe(
			'Import completed with 10 compatibility warnings.'
		);
		const warningRegion = screen.getByRole('region', { name: 'Compatibility warnings' });
		const resourceLists = expectVisibleWarningGroupsInOrder(warningRegion, warningGroups);
		let warningItemCount = 0;
		warningGroups.forEach(({ accessibleName, warnings: groupWarnings }, groupIndex) => {
			const groupList = resourceLists[groupIndex];
			expect(groupList).toHaveAccessibleName(accessibleName);
			const groupItems = within(groupList).getAllByRole('listitem');
			expect(groupItems).toHaveLength(groupWarnings.length);
			warningItemCount += groupItems.length;
			groupWarnings.forEach((warning, index) => {
				const item = within(groupItems[index]);
				expect(item.getByText(warning.message, { exact: true })).toBeInTheDocument();
				expect(item.getByText(warning.code, { exact: true })).toBeInTheDocument();
				expect(item.getByText(warning.locator, { exact: true })).toBeInTheDocument();
			});
		});
		expect(warningItemCount).toBe(warnings.length);
		expect(screen.getByRole('link', { name: /test search/i })).toHaveAttribute(
			'href',
			'/console/indexes/products%20migrated%2F2026?tab=search'
		);
		expect(screen.getByRole('link', { name: /view index/i })).toHaveAttribute(
			'href',
			'/console/indexes/products%20migrated%2F2026'
		);
		expect(container).not.toHaveTextContent(credentialCanary);
		expect(container).not.toHaveTextContent(sourcePayloadCanary);
		expect(container).not.toHaveTextContent('index-settings');
		expect(container).not.toHaveTextContent('index_settings');
		expect(container).not.toHaveTextContent(/\band \d+ more warnings?\b/);
	});

	it.each([
		['a status other than completed_with_warnings', 'completed', true],
		['an unobserved terminal outcome', 'completed_with_warnings', false]
	] as const)('renders warning payloads for %s', (_case, status, terminalOutcomeObserved) => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status,
				terminalOutcomeObserved,
				warnings: [
					{
						code: 'unsupported_synonym_type',
						message: 'Change this synonym type.',
						resource: 'synonyms',
						pageIndex: 2,
						itemIndex: 5,
						jsonPath: '$.synonyms[5]'
					}
				]
			})
		});

		expect(screen.getByTestId('migration-job-warning-summary').textContent).toBe(
			'This import has 1 compatibility warning.'
		);
		const warningRegion = screen.getByRole('region', { name: 'Compatibility warnings' });
		expect(within(warningRegion).getAllByRole('listitem')).toHaveLength(1);
	});

	it('renders no warning summary or region for an empty warning payload', () => {
		render(ImportJobDetail, {
			job: publicImportJob({ status: 'completed_with_warnings', warnings: [] })
		});

		expect(screen.queryByTestId('migration-job-warning-summary')).not.toBeInTheDocument();
		expect(
			screen.queryByRole('region', { name: 'Compatibility warnings' })
		).not.toBeInTheDocument();
	});

	it('renders stable typed failure copy without exposing the producer message or prior key', () => {
		const producerMessage = 'upstream detail included prior-key-canary';
		const { container } = render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				publicationDisposition: 'unchanged',
				resumable: true,
				error: { code: 'invalid_credentials' },
				legacyProducerMessage: producerMessage
			} as Partial<PublicAlgoliaImportJob> & { legacyProducerMessage: string }),
			capabilities: { cancel: false, resume: true, replace: false }
		});

		expect(screen.getByTestId('migration-job-error')).toHaveTextContent(
			'Algolia credentials were rejected. Reconnect with a valid key.'
		);
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(container).not.toHaveTextContent(producerMessage);
		expect(container).not.toHaveTextContent('prior-key-canary');
	});

	it('blocks unknown-disposition retry pending reconciliation and still keeps the key blank', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'interrupted',
				publicationDisposition: 'unknown',
				resumable: true,
				error: { code: 'interrupted' }
			}),
			capabilities: { cancel: false, resume: true, replace: false }
		});

		expect(screen.getByTestId('migration-job-disposition')).toHaveTextContent(
			'Destination safety is unproven.'
		);
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.getByRole('button', { name: /reconnect and retry/i })).toBeDisabled();
		expect(screen.getByTestId('migration-job-retry-policy')).toHaveTextContent(
			'Retry is blocked until destination reconciliation is complete.'
		);
	});

	it('renders replacement destination_changed copy without erasure language', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				mode: 'replace',
				destination: {
					kind: 'replace',
					target: 'existing_products',
					region: 'us-west-2'
				},
				status: 'failed',
				publicationDisposition: 'unknown',
				error: { code: 'destination_changed' }
			})
		});

		const disposition = screen.getByTestId('migration-job-disposition');
		expect(disposition).toHaveTextContent('Replacement stopped because the destination changed.');
		expect(disposition).toHaveTextContent(
			'Legitimate destination document or configuration writes were preserved'
		);
		expect(disposition).toHaveTextContent('both Algolia and fjcloud are quiet');
		expect(disposition).toHaveTextContent('new blank Algolia key');
		expect(disposition).not.toHaveTextContent(/eras|delet/i);
	});

	it('disables Stage 5 retry entry points under runtime backpressure with typed retry-after copy', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				publicationDisposition: 'unchanged',
				resumable: true
			}),
			admission: {
				admitted: false,
				reason: 'runtime_backpressure',
				message: 'Import workers are saturated.',
				retryAfterSeconds: 90
			},
			capabilities: { cancel: false, resume: true, replace: false }
		});

		const retryPanel = screen.getByTestId('migration-job-retry-panel');
		expect(retryPanel).toHaveTextContent('Imports are temporarily busy');
		expect(retryPanel).toHaveTextContent('Retry after 90 seconds');
		expect(within(retryPanel).getByRole('button', { name: /reconnect and retry/i })).toBeDisabled();
		expect(within(retryPanel).getByLabelText(/algolia api key/i)).toHaveValue('');
	});

	it.each([
		['absent', undefined],
		['all false', NO_MIGRATION_CAPABILITIES],
		['partial cancel omitted', { resume: true, replace: true } as AlgoliaMigrationCapabilities],
		[
			'malformed cancel by cast',
			{ cancel: 'true', resume: true, replace: true } as unknown as AlgoliaMigrationCapabilities
		]
	])(
		'renders no cancel affordance, placeholder, tooltip, hint, or inert control for %s capability inputs',
		(_name, capabilities) => {
			render(ImportJobDetail, {
				job: publicImportJob({ status: 'copying_documents' }),
				capabilities,
				onCancelIntent: () => {}
			});

			expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
			expect(screen.queryByText(/cancel unavailable/i)).not.toBeInTheDocument();
			expect(screen.queryByTitle(/cancel/i)).not.toBeInTheDocument();
		}
	);

	it.each([
		['absent', undefined],
		['all false', NO_MIGRATION_CAPABILITIES],
		['partial resume omitted', { cancel: true, replace: true } as AlgoliaMigrationCapabilities],
		[
			'malformed resume by cast',
			{ cancel: true, resume: 'true', replace: true } as unknown as AlgoliaMigrationCapabilities
		]
	])(
		'renders no resume affordance, placeholder, tooltip, hint, or inert control for %s capability inputs',
		(_name, capabilities) => {
			render(ImportJobDetail, {
				job: publicImportJob({
					status: 'failed',
					resumable: true,
					publicationDisposition: 'unchanged',
					resumeDeadline: '2026-07-19T18:30:00Z',
					resumeProvenance: 'Must remain hidden without the Resume capability.'
				}),
				capabilities,
				onResumeIntent: () => {}
			});

			expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
			expect(
				screen.queryByRole('button', { name: /reconnect and retry/i })
			).not.toBeInTheDocument();
			expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
			expect(screen.queryByTestId('migration-job-retry-panel')).not.toBeInTheDocument();
			expect(screen.queryByTestId('migration-job-resume-deadline')).not.toBeInTheDocument();
			expect(screen.queryByText(/must remain hidden/i)).not.toBeInTheDocument();
			expect(screen.queryByText(/resume unavailable/i)).not.toBeInTheDocument();
			expect(screen.queryByPlaceholderText(/resume|api key/i)).not.toBeInTheDocument();
			expect(screen.queryByTitle(/resume/i)).not.toBeInTheDocument();
		}
	);

	it('renders only the cancel arm when the cancel capability is true', () => {
		render(ImportJobDetail, {
			job: publicImportJob({ status: 'copying_documents' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent: () => {},
			onResumeIntent: () => {}
		});

		expect(screen.getByRole('button', { name: /cancel import/i })).toBeEnabled();
		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /replace/i })).not.toBeInTheDocument();
	});

	it('renders only the resume arm when the resume capability and job fields are true', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				resumable: true,
				publicationDisposition: 'unchanged'
			}),
			capabilities: { cancel: false, resume: true, replace: false },
			onCancelIntent: () => {},
			onResumeIntent: () => {}
		});

		expect(screen.getByRole('button', { name: /resume import/i })).toBeDisabled();
		expect(screen.getByLabelText(/algolia api key/i)).toHaveValue('');
		expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /replace/i })).not.toBeInTheDocument();
	});

	it('does not let replace or an availability-like flag cross-enable job actions', () => {
		render(ImportJobDetail, {
			job: publicImportJob({ status: 'copying_documents' }),
			capabilities: {
				cancel: false,
				resume: false,
				replace: true,
				available: true
			} as AlgoliaMigrationCapabilities,
			onCancelIntent: () => {},
			onResumeIntent: () => {}
		});

		expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /replace/i })).not.toBeInTheDocument();
	});

	it.each(NON_TERMINAL_IMPORT_STATUSES)(
		'confirms cancel with exact safety copy for non-terminal %s jobs',
		async (status) => {
			const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
			const onCancelIntent = vi.fn();
			render(ImportJobDetail, {
				job: publicImportJob({ status }),
				capabilities: { cancel: true, resume: false, replace: false },
				onCancelIntent
			});

			await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));

			expect(confirm).toHaveBeenCalledWith(CANCEL_CONFIRM_COPY);
			expect(onCancelIntent).not.toHaveBeenCalled();
		}
	);

	it('emits one cancel intent after confirmation and disables duplicate submits', async () => {
		vi.spyOn(window, 'confirm').mockReturnValue(true);
		const onCancelIntent = vi.fn();
		render(ImportJobDetail, {
			job: publicImportJob({ status: 'copying_documents' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		});
		const cancelButton = screen.getByRole('button', { name: /cancel import/i });

		await fireEvent.click(cancelButton);
		await fireEvent.click(cancelButton);

		expect(cancelButton).toBeDisabled();
		expect(onCancelIntent).toHaveBeenCalledOnce();
	});

	it('resets one-shot intent state when the detail receives a different job', async () => {
		vi.spyOn(window, 'confirm').mockReturnValue(true);
		const onCancelIntent = vi.fn();
		const { rerender } = render(ImportJobDetail, {
			job: publicImportJob({ id: 'job_first', status: 'copying_documents' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		});

		await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));
		expect(screen.getByRole('button', { name: /cancel import/i })).toBeDisabled();

		await rerender({
			job: publicImportJob({ id: 'job_second', status: 'copying_documents' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		});

		expect(screen.getByRole('button', { name: /cancel import/i })).toBeEnabled();
	});

	it('re-enables cancel after a same-job reload cycle ends without a state change', async () => {
		vi.spyOn(window, 'confirm').mockReturnValue(true);
		const onCancelIntent = vi.fn();
		const job = publicImportJob({ status: 'copying_documents' });
		const props = {
			job,
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		};
		const { rerender } = render(ImportJobDetail, { ...props, reloading: false });
		await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));
		expect(screen.getByRole('button', { name: /cancel import/i })).toBeDisabled();
		await rerender({ ...props, reloading: true });
		await rerender({ ...props, reloading: false });
		expect(screen.getByRole('button', { name: /cancel import/i })).toBeEnabled();
	});

	it('keeps cancelling in progress and renders completed copy after a promotion race', async () => {
		vi.spyOn(window, 'confirm').mockReturnValue(true);
		const onCancelIntent = vi.fn();
		const { rerender } = render(ImportJobDetail, {
			job: publicImportJob({ status: 'copying_documents' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		});

		await fireEvent.click(screen.getByRole('button', { name: /cancel import/i }));
		await rerender({
			job: publicImportJob({ status: 'cancelling' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		});
		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Cancelling');
		expect(screen.getByTestId('migration-job-safe-reload')).toBeInTheDocument();

		await rerender({
			job: publicImportJob({ status: 'completed', publicationDisposition: 'promoted' }),
			capabilities: { cancel: true, resume: false, replace: false },
			onCancelIntent
		});
		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Completed');
		expect(screen.getByTestId('migration-job-disposition')).toHaveTextContent(
			'The destination index was promoted.'
		);
		expect(screen.queryByText(/stopped before completion/i)).not.toBeInTheDocument();
	});

	it('states cancelled jobs leave the destination unchanged and offers a fresh import only', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'cancelled',
				publicationDisposition: 'unchanged',
				resumable: true
			}),
			capabilities: { cancel: true, resume: true, replace: false },
			onCancelIntent: () => {},
			onResumeIntent: () => {}
		});

		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Cancelled');
		expect(screen.getByTestId('migration-job-disposition')).toHaveTextContent(
			'The existing destination index is unchanged.'
		);
		expect(screen.queryByTestId('migration-job-error')).not.toBeInTheDocument();
		expect(screen.getByRole('link', { name: /start a new import/i })).toHaveAttribute(
			'href',
			'/console/migrate'
		);
		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByText(/new imports paused/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/eras|delet/i)).not.toBeInTheDocument();
	});

	it.each([
		['invalid credentials', 'failed', 'invalid_credentials'],
		['missing source permission', 'failed', 'missing_source_permission'],
		['engine-marked interruption', 'interrupted', 'interrupted']
	] as const)(
		'renders resume only for a resumable %s fixture when the capability is true',
		async (_name, status, code) => {
			render(ImportJobDetail, {
				job: publicImportJob({
					status,
					resumable: true,
					publicationDisposition: 'unchanged',
					error: { code }
				}),
				capabilities: { cancel: false, resume: true, replace: false },
				onResumeIntent: () => {}
			});

			const resumeButton = screen.getByRole('button', { name: /resume import/i });
			expect(resumeButton).toBeDisabled();
			expect(screen.getByTestId('migration-job-retry-policy')).toHaveTextContent(
				'Already-imported records are skipped'
			);
			await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
				target: { value: 'fresh-resume-key' }
			});
			expect(resumeButton).toBeEnabled();
			expect(screen.queryByRole('button', { name: /cancel import/i })).not.toBeInTheDocument();
			expect(screen.queryByRole('link', { name: /start a new import/i })).not.toBeInTheDocument();
		}
	);

	it('shows the resume deadline as an absolute UTC time with its provenance when supplied', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'interrupted',
				resumable: true,
				publicationDisposition: 'unchanged',
				error: { code: 'interrupted' },
				resumeDeadline: '2026-07-19T18:30:00Z',
				resumeProvenance: 'Deadline set by the migration engine at interruption.'
			}),
			capabilities: { cancel: false, resume: true, replace: false },
			onResumeIntent: () => {}
		});

		const deadline = screen.getByTestId('migration-job-resume-deadline');
		expect(deadline).toHaveTextContent('Jul 19, 2026');
		expect(deadline).toHaveTextContent('6:30');
		expect(deadline).toHaveTextContent('UTC');
		expect(deadline).toHaveTextContent('Deadline set by the migration engine at interruption.');
	});

	it('omits the resume deadline line entirely when no deadline is supplied', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				resumable: true,
				publicationDisposition: 'unchanged',
				error: { code: 'invalid_credentials' },
				resumeDeadline: null,
				resumeProvenance: null
			}),
			capabilities: { cancel: false, resume: true, replace: false },
			onResumeIntent: () => {}
		});

		expect(screen.queryByTestId('migration-job-resume-deadline')).not.toBeInTheDocument();
	});

	it('emits one fresh-key resume intent, clears the key, and disables duplicate submits', async () => {
		const onResumeIntent = vi.fn();
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				resumable: true,
				publicationDisposition: 'unchanged',
				error: { code: 'invalid_credentials' }
			}),
			capabilities: { cancel: false, resume: true, replace: false },
			onResumeIntent
		});
		const resumeButton = screen.getByRole('button', { name: /resume import/i });
		const apiKey = screen.getByLabelText(/algolia api key/i);

		expect(resumeButton).toBeDisabled();
		await fireEvent.input(apiKey, { target: { value: 'fresh-secret-key' } });
		await fireEvent.click(resumeButton);
		await fireEvent.click(resumeButton);

		expect(resumeButton).toBeDisabled();
		expect(apiKey).toHaveValue('');
		expect(onResumeIntent).toHaveBeenCalledExactlyOnceWith({ apiKey: 'fresh-secret-key' });
	});

	it('re-enables resume after a same-job reload cycle ends without a state change', async () => {
		const onResumeIntent = vi.fn();
		const job = publicImportJob({
			status: 'failed',
			resumable: true,
			publicationDisposition: 'unchanged',
			error: { code: 'invalid_credentials' }
		});
		const props = {
			job,
			capabilities: { cancel: false, resume: true, replace: false },
			onResumeIntent
		};
		const { rerender } = render(ImportJobDetail, { ...props, reloading: false });
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'fresh-secret-key' }
		});
		await fireEvent.click(screen.getByRole('button', { name: /resume import/i }));
		expect(screen.getByRole('button', { name: /resume import/i })).toBeDisabled();
		await rerender({ ...props, reloading: true });
		await rerender({ ...props, reloading: false });
		await fireEvent.input(screen.getByLabelText(/algolia api key/i), {
			target: { value: 'fresh-secret-key-2' }
		});
		expect(screen.getByRole('button', { name: /resume import/i })).toBeEnabled();
	});

	it('keeps resume credentials only in the live input and explicit intent callback', async () => {
		const setItem = vi.spyOn(Storage.prototype, 'setItem');
		const pushState = vi.spyOn(window.history, 'pushState');
		const replaceState = vi.spyOn(window.history, 'replaceState');
		const onResumeIntent = vi.fn();
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				resumable: true,
				publicationDisposition: 'unchanged',
				error: { code: 'invalid_credentials' }
			}),
			capabilities: { cancel: false, resume: true, replace: false },
			onResumeIntent
		});

		const apiKey = screen.getByLabelText(/algolia api key/i);
		expect(apiKey).toHaveAttribute('type', 'password');
		expect(apiKey).toHaveAttribute('autocomplete', 'off');

		await fireEvent.input(apiKey, { target: { value: RESUME_API_KEY_CANARY } });

		expect(apiKey).toHaveValue(RESUME_API_KEY_CANARY);
		expect(document.body).not.toHaveTextContent(RESUME_API_KEY_CANARY);
		expect(document.body.innerHTML).not.toContain(RESUME_API_KEY_CANARY);
		expect(window.location.href).not.toContain(RESUME_API_KEY_CANARY);
		expect(document.querySelector('form')).not.toBeInTheDocument();
		expect(
			Array.from(document.querySelectorAll('form')).flatMap((form) =>
				Array.from(new FormData(form).values())
			)
		).not.toContain(RESUME_API_KEY_CANARY);
		expect(setItem).not.toHaveBeenCalled();
		expect(pushState).not.toHaveBeenCalled();
		expect(replaceState).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByRole('button', { name: /resume import/i }));

		expect(onResumeIntent).toHaveBeenCalledExactlyOnceWith({ apiKey: RESUME_API_KEY_CANARY });
		expect(apiKey).toHaveValue('');
		expect(document.body.innerHTML).not.toContain(RESUME_API_KEY_CANARY);
	});

	it('offers retry from scratch only for non-resumable terminal failures', () => {
		render(ImportJobDetail, {
			job: publicImportJob({
				status: 'failed',
				resumable: false,
				publicationDisposition: 'unchanged',
				error: { code: 'not_resumable' }
			}),
			capabilities: { cancel: false, resume: true, replace: false },
			onResumeIntent: () => {}
		});

		expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Failed');
		expect(screen.getByTestId('migration-job-disposition')).toHaveTextContent(
			'The existing destination index is unchanged.'
		);
		expect(screen.getByTestId('migration-job-error')).toHaveTextContent(
			'This import cannot be resumed. Start a new import instead.'
		);
		expect(screen.getByRole('link', { name: /start a new import/i })).toHaveAttribute(
			'href',
			'/console/migrate'
		);
		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /reconnect and retry/i })).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/algolia api key/i)).not.toBeInTheDocument();
	});

	it.each(['runtime_backpressure', 'operational_pause'] as const)(
		'disables resume during %s without hiding job status',
		(reason) => {
			render(ImportJobDetail, {
				job: publicImportJob({
					status: 'interrupted',
					resumable: true,
					publicationDisposition: 'unchanged',
					error: { code: 'interrupted' }
				}),
				admission: {
					admitted: false,
					reason,
					message: 'Migration starts are paused.',
					retryAfterSeconds: null
				},
				capabilities: { cancel: true, resume: true, replace: false },
				onResumeIntent: () => {}
			});

			expect(screen.getByTestId('migration-job-status')).toHaveTextContent('Interrupted');
			expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
			expect(screen.getByTestId('migration-job-retry-policy')).toHaveTextContent(
				'Migration starts are paused.'
			);
		}
	);

	it.each([
		['copying_documents', 'operational_pause', 'Migration starts are paused.'],
		['resuming', 'operational_pause', 'Migration starts are paused.'],
		['promoting', 'repository_backpressure', 'Repository ACKs are delayed.']
	] as const)('keeps status and cancel usable for %s jobs during %s', (status, reason, message) => {
		render(ImportJobDetail, {
			job: publicImportJob({ status }),
			admission: {
				admitted: false,
				reason,
				message,
				retryAfterSeconds: null
			},
			capabilities: { cancel: true, resume: true, replace: false },
			onCancelIntent: () => {}
		});

		expect(screen.getByTestId('migration-job-status')).toHaveTextContent(
			status === 'copying_documents'
				? 'Copying documents'
				: status === 'resuming'
					? 'Resuming'
					: 'Promoting'
		);
		expect(screen.getByTestId('migration-job-safe-reload')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /cancel import/i })).toBeEnabled();
		expect(screen.queryByRole('button', { name: /resume import/i })).not.toBeInTheDocument();
		expect(screen.queryByText(message)).not.toBeInTheDocument();
	});
});
