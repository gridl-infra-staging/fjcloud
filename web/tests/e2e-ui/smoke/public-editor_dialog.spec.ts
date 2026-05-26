import { test, expect } from '../../fixtures/fixtures';

test('submits all field types and echoes normalized payload', async ({ page }) => {
	await page.goto('/dev_editor_dialog_demo');
	await page.getByTestId('demo-open-successful-save').click();

	await expect(page.getByRole('dialog')).toBeVisible();
	await expect(page.getByLabel('Title')).toHaveAttribute('maxlength', '120');
	await expect(page.getByLabel('Limit')).toHaveAttribute('min', '1');
	await expect(page.getByLabel('Limit')).toHaveAttribute('max', '100');
	await expect(page.getByLabel('Limit')).toHaveAttribute('step', '1');
	await page.getByLabel('Title').fill('Demo title');
	await page.getByLabel('Description').fill('Demo description');
	await page.getByLabel('Model').selectOption('trending-facets');
	await page.getByLabel('Facet Filters').selectOption(['brand', 'category']);
	await page.getByLabel('Limit').fill('42');
	await page.getByRole('checkbox', { name: 'Enabled' }).check();
	await page.getByRole('radio', { name: 'Aggressive' }).check();
	await page.getByLabel('Activation time').fill('2026-05-25T11:30');

	await page.getByTestId('editor-dialog-field-keywords-0').fill('featured');
	await page.getByRole('button', { name: 'Add keyword' }).click();
	await page.getByTestId('editor-dialog-field-keywords-1').fill('seasonal');

	await page.getByTestId('editor-dialog-field-boosts-0-attribute').fill('brand');
	await page.getByTestId('editor-dialog-field-boosts-0-weight').fill('7');
	await page.getByRole('button', { name: 'Add boost rule' }).click();
	await page.getByTestId('editor-dialog-field-boosts-1-attribute').fill('category');
	await page.getByTestId('editor-dialog-field-boosts-1-weight').fill('5');

	await page.getByTestId('editor-dialog-save').click();

	await expect(page.getByRole('dialog')).toBeHidden();
	await expect(page.getByTestId('demo-status')).toHaveText('Save succeeded');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"title": "Demo title"');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"limit": 42');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"facets": [');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"brand"');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"category"');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"enabled": true');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"rankingMode": "aggressive"');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"keywords": [');
	await expect(page.getByTestId('demo-last-payload')).toContainText('"boosts": [');
});

test('enforces modal focus, dirty confirm, pending save, reject alert, and successful reopen', async ({
	page
}) => {
	await page.goto('/dev_editor_dialog_demo');

	await page.getByTestId('demo-open-create').click();
	await expect(page.getByLabel('Title')).toBeFocused();

	await page.getByTestId('demo-open-dirty-dismiss').click();
	await page.getByLabel('Title').fill('dirty value');
	await page.getByTestId('editor-dialog-cancel').click();
	await expect(page.getByTestId('editor-dialog-discard')).toBeVisible();
	await page.getByTestId('editor-dialog-keep-editing').click();
	await expect(page.getByRole('dialog')).toBeVisible();

	await page.getByTestId('editor-dialog-cancel').click();
	await page.getByTestId('editor-dialog-discard').click();
	await expect(page.getByRole('dialog')).toBeHidden();

	await page.getByTestId('demo-open-pending-save').click();
	await page.getByLabel('Title').fill('pending value');
	await page.getByTestId('editor-dialog-save').click();
	await expect(page.getByTestId('editor-dialog-save')).toHaveText('Saving...');
	await expect(page.getByTestId('editor-dialog-close')).toBeDisabled();
	await expect(page.getByTestId('editor-dialog-cancel')).toBeDisabled();
	await expect(page.getByRole('dialog')).toBeVisible();
	await page.getByTestId('demo-resolve-pending-save').click();
	await expect(page.getByRole('dialog')).toBeHidden();

	await page.getByTestId('demo-open-rejected-save').click();
	await page.getByLabel('Title').fill('reject value');
	await page.getByTestId('editor-dialog-save').click();
	await expect(page.getByRole('alert').filter({ hasText: 'Demo rejected save' })).toBeVisible();

	await page.getByTestId('demo-open-successful-save').click();
	await page.getByLabel('Title').fill('final value');
	await page.getByTestId('editor-dialog-save').click();
	await expect(page.getByRole('dialog')).toBeHidden();
	await page.getByTestId('demo-open-edit').click();
	await expect(page.getByRole('dialog')).toBeVisible();
});
