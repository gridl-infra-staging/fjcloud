export interface NormalizedBrowserFailure {
	status: number;
	error: {
		message: string;
		supportReference: string;
		backendRequestId?: string;
	};
}

export const NORMALIZED_BROWSER_ERROR_FAILURE: NormalizedBrowserFailure = {
	status: 500,
	error: {
		message:
			'Uncaught Error: ECONNREFUSED while reaching http://localhost:5173/dashboard (stack trace omitted)',
		supportReference: 'web-a1b2c3d4e5f6'
	}
};

export const NORMALIZED_BROWSER_REJECTION_FAILURE: NormalizedBrowserFailure = {
	status: 500,
	error: {
		message:
			'Unhandled promise rejection: {"host":"postgres.internal","port":5432,"request":"req-backend-999"}',
		supportReference: 'web-fedcba987654'
	}
};
