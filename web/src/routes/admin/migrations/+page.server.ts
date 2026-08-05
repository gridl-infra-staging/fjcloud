import { fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import type { AdminMigration } from '$lib/admin-client';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

const ACTIVE_STATUSES = new Set(['pending', 'replicating', 'cutting_over']);

export const load: PageServerLoad = async (event) => {
	event.depends('admin:migrations');

	const { adminClient: client } = await requireDurableAdminSession(event);

	try {
		const [activeMigrations, recentMigrationsRaw] = await Promise.all([
			client.getMigrations({ status: 'active', limit: 50 }),
			client.getMigrations({ limit: 100 })
		]);

		const activeIds = new Set(activeMigrations.map((migration) => migration.id));
		const recentMigrations = recentMigrationsRaw.filter(
			(migration) => !activeIds.has(migration.id) && !ACTIVE_STATUSES.has(migration.status)
		);

		return { activeMigrations, recentMigrations };
	} catch (error) {
		redirectIfAdminSessionAuthError(error);
		return {
			activeMigrations: [] as AdminMigration[],
			recentMigrations: [] as AdminMigration[]
		};
	}
};

export const actions = {
	trigger: async (event) => {
		const { adminClient: client } = await requireDurableAdminSession(event);

		const formData = await event.request.formData();
		const indexName = formData.get('index_name');
		const destVmId = formData.get('dest_vm_id');

		if (typeof indexName !== 'string' || indexName.trim().length === 0) {
			return fail(400, {
				success: false,
				error: 'Index name is required'
			});
		}

		if (typeof destVmId !== 'string' || destVmId.trim().length === 0) {
			return fail(400, {
				success: false,
				error: 'Destination VM ID is required'
			});
		}

		try {
			const result = await client.triggerMigration({
				index_name: indexName.trim(),
				dest_vm_id: destVmId.trim()
			});
			return {
				success: true,
				message: 'Migration started',
				migrationId: result.migration_id
			};
		} catch (err) {
			redirectIfAdminSessionAuthError(err);
			return fail(400, {
				success: false,
				error: err instanceof Error ? err.message : 'Failed to trigger migration'
			});
		}
	}
} satisfies Actions;
