import { describe, expect, it } from 'vitest';

import { formResultOwnerTab } from './index_detail_form_result_tabs';

describe('formResultOwnerTab', () => {
	it('routes query suggestions form results to the Suggestions tab', () => {
		expect(formResultOwnerTab({ qsConfigSaved: true })).toBe('suggestions');
		expect(formResultOwnerTab({ qsConfigDeleted: true })).toBe('suggestions');
		expect(formResultOwnerTab({ qsBuildQueued: true })).toBe('suggestions');
		expect(formResultOwnerTab({ qsConfigError: 'Invalid config' })).toBe('suggestions');
	});

	it('does not reroute unrelated or empty form results', () => {
		expect(formResultOwnerTab(null)).toBeNull();
		expect(formResultOwnerTab({ qsConfigError: '' })).toBeNull();
	});

	it('routes rule form results to the Merchandising tab', () => {
		expect(formResultOwnerTab({ ruleSaved: true })).toBe('merchandising');
		expect(formResultOwnerTab({ ruleDeleted: true })).toBe('merchandising');
		expect(formResultOwnerTab({ rulesCleared: true })).toBe('merchandising');
		expect(formResultOwnerTab({ ruleError: 'Invalid rule payload' })).toBe('merchandising');
		expect(formResultOwnerTab({ rulesClearError: 'Failed to clear rules' })).toBe('merchandising');
		expect(formResultOwnerTab({ ruleError: '' })).toBeNull();
		expect(formResultOwnerTab({ rulesClearError: '' })).toBeNull();
	});
});
