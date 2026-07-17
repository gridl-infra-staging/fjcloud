export const FIXTURE_BOOTSTRAP_REMEDIATION_COMMAND = 'scripts/bootstrap-env-local.sh';

export type FixtureSetupFailureParams = {
	setupName: string;
	expectedPath: string;
	currentPath: string;
	apiUrl: string;
	adminKey?: string;
	alertText?: string | null;
	responseStatus?: number;
	responseUrl?: string;
	bootstrapCommand?: string;
};

const VERIFY_EMAIL_TOKEN_PATH_PATTERN = /\/verify-email\/[A-Za-z0-9_-]+/g;
const URL_USERINFO_PATTERN = /\b([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^/\s@]+)@/g;
const SENSITIVE_URL_PARAM_PATTERN =
	/([?#&](?:access_token|refresh_token|id_token|session(?:_token)?|token|verification_token|verificationToken|secret|key|code|state)=)[^&#\s]*/gi;
const BEARER_TOKEN_PATTERN = /\bBearer\s+[A-Za-z0-9._~+/=-]+\b/g;
const BASIC_AUTH_PATTERN = /\bBasic\s+[A-Za-z0-9._~+/=-]+\b/g;
const JSON_SECRET_FIELD_PATTERN =
	/((?:"(?:access_token|refresh_token|id_token|session_token|token|verification_token|verificationToken|secret|api_key|admin_key|jwt_secret|password)"\s*:\s*"))([^"]+)(")/gi;

function formatAdminKeyFingerprint(adminKey?: string): string {
	if (!adminKey?.trim()) {
		return '(missing)';
	}

	const normalizedAdminKey = adminKey.trim();
	return `(present, len=${normalizedAdminKey.length})`;
}

export function redactSensitiveDiagnostics(value: string): string {
	return value
		.replace(URL_USERINFO_PATTERN, '$1[REDACTED]@')
		.replace(VERIFY_EMAIL_TOKEN_PATH_PATTERN, '/verify-email/[REDACTED]')
		.replace(SENSITIVE_URL_PARAM_PATTERN, '$1[REDACTED]')
		.replace(BEARER_TOKEN_PATTERN, 'Bearer [REDACTED]')
		.replace(BASIC_AUTH_PATTERN, 'Basic [REDACTED]')
		.replace(JSON_SECRET_FIELD_PATTERN, '$1[REDACTED]$3');
}

function formatResponseDiagnostic(responseStatus?: number, responseUrl?: string): string {
	if (responseStatus !== undefined && responseUrl) {
		return `status ${responseStatus} at ${redactSensitiveDiagnostics(responseUrl)}`;
	}
	if (responseStatus !== undefined) {
		return `status ${responseStatus}`;
	}
	if (responseUrl) {
		return `URL ${redactSensitiveDiagnostics(responseUrl)}`;
	}
	return '(none observed)';
}

/** Build a non-secret setup failure message for browser auth fixtures. */
export function formatFixtureSetupFailure({
	setupName,
	expectedPath,
	currentPath,
	apiUrl,
	adminKey,
	alertText,
	responseStatus,
	responseUrl,
	bootstrapCommand = FIXTURE_BOOTSTRAP_REMEDIATION_COMMAND
}: FixtureSetupFailureParams): string {
	const normalizedAlertText = redactSensitiveDiagnostics(alertText?.trim() || '(none)');
	const remediationMessage =
		`Run ${bootstrapCommand} to bootstrap .env.local, then start the local stack with scripts/local-dev-up.sh and the Rust API with scripts/api-dev.sh. ` +
		'If you override BASE_URL, start the web frontend with scripts/web-dev.sh too. See docs/runbooks/local-dev.md for setup instructions.';

	return [
		`${setupName} failed before reaching ${expectedPath}. Current URL: ${redactSensitiveDiagnostics(currentPath)}`,
		`API URL: ${redactSensitiveDiagnostics(apiUrl)}`,
		`Admin key fingerprint: ${formatAdminKeyFingerprint(adminKey)}`,
		`Visible alert text: ${normalizedAlertText}`,
		`Login response: ${formatResponseDiagnostic(responseStatus, responseUrl)}`,
		`Remediation: ${remediationMessage}`
	].join('\n');
}
