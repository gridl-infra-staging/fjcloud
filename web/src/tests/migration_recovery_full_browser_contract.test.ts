import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const migrationRecoverySource = readFileSync(
	join(process.cwd(), 'tests/e2e-ui/full/migration-recovery.spec.ts'),
	'utf8'
);

describe('migration recovery full-browser contract', () => {
	it('keeps the full-browser scenario focused on the fail-closed unavailable page', () => {
		expect(migrationRecoverySource).toContain("test.describe('Migration unavailable page'");
		expect(migrationRecoverySource).toContain("await page.goto('/console/migrate');");
		expect(migrationRecoverySource).toContain(
			"await expect(page.getByTestId('migration-unavailable')).toContainText("
		);
		expect(migrationRecoverySource).toContain(
			"await expect(page.getByRole('button', { name: 'Browse indexes' })).toHaveCount(0);"
		);
		expect(migrationRecoverySource).toContain(
			"await expect(page.getByTestId('migrate-button')).toHaveCount(0);"
		);
		expect(migrationRecoverySource).not.toContain('ensureLocalSharedVmInventory');
		expect(migrationRecoverySource).not.toContain('create-index');
	});
});
