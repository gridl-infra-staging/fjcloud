import { execFileSync, spawnSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

type PostgresConnection = {
	host: string;
	port: string;
	user: string;
	password: string;
	database: string;
};

function parsePostgresConnection(databaseUrl: string): PostgresConnection {
	const parsed = new URL(databaseUrl);
	const database = parsed.pathname.replace(/^\//, '');
	return {
		host: parsed.hostname || '127.0.0.1',
		port: parsed.port || '5432',
		user: decodeURIComponent(parsed.username),
		password: decodeURIComponent(parsed.password),
		database
	};
}

export function quoteSqlLiteral(value: string): string {
	return `'${value.replace(/'/g, "''")}'`;
}

export function runSqlWithPsqlFallback(databaseUrl: string, sql: string, context: string): string {
	const connection = parsePostgresConnection(databaseUrl);
	const psqlArgs = ['-v', 'ON_ERROR_STOP=1', '-tA', '-c', sql];
	const psqlConnectionArgs = [
		'-h',
		connection.host,
		'-p',
		connection.port,
		'-U',
		connection.user,
		'-d',
		connection.database
	];

	const hostPsql = spawnSync('psql', [...psqlConnectionArgs, ...psqlArgs], {
		cwd: REPO_ROOT,
		encoding: 'utf8',
		env: {
			...process.env,
			PGPASSWORD: connection.password,
			PSQLRC: '/dev/null'
		}
	});

	if (hostPsql.status === 0) {
		return hostPsql.stdout;
	}

	if (hostPsql.error && hostPsql.error.name !== 'Error') {
		throw hostPsql.error;
	}

	if (hostPsql.error?.message.includes('ENOENT')) {
		try {
			return execFileSync(
				'docker',
				[
					'compose',
					'exec',
					'-T',
					'-e',
					'PGPASSWORD',
					'-e',
					'PSQLRC',
					'postgres',
					'psql',
					'-U',
					connection.user,
					'-d',
					connection.database,
					...psqlArgs
				],
				{
					cwd: REPO_ROOT,
					encoding: 'utf8',
					env: {
						...process.env,
						PGPASSWORD: connection.password,
						PSQLRC: '/dev/null'
					},
					stdio: 'pipe'
				}
			);
		} catch (dockerError: unknown) {
			const detail = dockerError instanceof Error ? dockerError.message : String(dockerError);
			throw new Error(
				'psql is not installed and docker compose fallback also failed. ' +
					'Resolution: either install psql (e.g. `brew install libpq`) or ' +
					'ensure `docker compose exec postgres psql` is available. ' +
					`Context: ${context}. Docker error: ${detail}`
			);
		}
	}

	throw new Error(`${context} failed. stderr: ${hostPsql.stderr || '(none)'}`);
}
