import { expect, test } from '../../fixtures/fixtures';
import { TOAST_DURATION_MS } from '../../../src/lib/toast_contract';

const DEMO_TOAST_TEXT = 'Shared toast rendered from demo route';

test.use({ video: 'on' });

test('renders a shared toast from the public demo route and auto-dismisses it', async ({
	page
}) => {
	await page.goto('/dev_editor_dialog_demo');

	await page.getByTestId('demo-trigger-toast').click();

	const toastMessage = page.getByText(DEMO_TOAST_TEXT);
	await expect(toastMessage).toBeVisible();
	await page.mouse.move(0, 0);
	await expect(toastMessage).toBeHidden({ timeout: TOAST_DURATION_MS + 2_000 });
});
