import type { IndexDetailTabId } from './index_detail_tabs';

export type IndexDetailFormResultTabInput = Record<string, unknown> & {
	qsConfigSaved?: boolean;
	qsConfigDeleted?: boolean;
	qsBuildQueued?: boolean;
	qsConfigError?: string;
	ruleSaved?: boolean;
	ruleDeleted?: boolean;
	rulesCleared?: boolean;
	ruleError?: string;
	rulesClearError?: string;
};

export function formResultOwnerTab(
	result: IndexDetailFormResultTabInput | null
): IndexDetailTabId | null {
	if (!result) return null;
	if (
		result.qsConfigSaved ||
		result.qsConfigDeleted ||
		result.qsBuildQueued ||
		Boolean(result.qsConfigError)
	) {
		return 'suggestions';
	}
	if (
		result.ruleSaved ||
		result.ruleDeleted ||
		result.rulesCleared ||
		Boolean(result.ruleError) ||
		Boolean(result.rulesClearError)
	) {
		return 'merchandising';
	}
	return null;
}
