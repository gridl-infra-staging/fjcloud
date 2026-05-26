import { defineConfig } from '@playwright/test';
import baseConfig from '../../playwright.config';

const PLAYWRIGHT_CWD_LOCAL_WEB_PORT = '5183';
const CWD_LOCAL_BASE_URL = `http://localhost:${PLAYWRIGHT_CWD_LOCAL_WEB_PORT}`;
const PLAYWRIGHT_CWD_LOCAL_API_PORT = '33183';
const PLAYWRIGHT_CWD_LOCAL_API_S3_PORT = '33184';
const CWD_LOCAL_API_BASE_URL = `http://127.0.0.1:${PLAYWRIGHT_CWD_LOCAL_API_PORT}`;

// Keep env-reading specs aligned with the cwd-local dedicated port even when the
// parent shell exported a different BASE_URL for some other workspace.
process.env.BASE_URL = CWD_LOCAL_BASE_URL;
process.env.API_URL = CWD_LOCAL_API_BASE_URL;
process.env.API_BASE_URL = CWD_LOCAL_API_BASE_URL;
process.env.LISTEN_ADDR = `0.0.0.0:${PLAYWRIGHT_CWD_LOCAL_API_PORT}`;
process.env.S3_LISTEN_ADDR = `0.0.0.0:${PLAYWRIGHT_CWD_LOCAL_API_S3_PORT}`;

const localWebServer =
	typeof baseConfig.webServer === 'object' &&
	baseConfig.webServer !== null &&
	'command' in baseConfig.webServer &&
	typeof baseConfig.webServer.command === 'string'
		? {
				...baseConfig.webServer,
				command: baseConfig.webServer.command
					.replace('../scripts/', '../../../scripts/')
					.replace('--port 5173', `--port ${PLAYWRIGHT_CWD_LOCAL_WEB_PORT}`),
				env: {
					...(baseConfig.webServer.env ?? {}),
					API_URL: CWD_LOCAL_API_BASE_URL,
					API_BASE_URL: CWD_LOCAL_API_BASE_URL,
					LISTEN_ADDR: `0.0.0.0:${PLAYWRIGHT_CWD_LOCAL_API_PORT}`,
					S3_LISTEN_ADDR: `0.0.0.0:${PLAYWRIGHT_CWD_LOCAL_API_S3_PORT}`
				},
				url: CWD_LOCAL_BASE_URL
			}
		: baseConfig.webServer;

// Running from tests/e2e-ui should reuse the root config contract while rebasing
// launcher paths relative to this cwd-local config file.
// Use a dedicated local port so strict-port startup does not collide with
// sibling worktree stacks that own 5173.
export default defineConfig({
	...baseConfig,
	testDir: '..',
	use: {
		...baseConfig.use,
		baseURL: CWD_LOCAL_BASE_URL
	},
	webServer: localWebServer
});
