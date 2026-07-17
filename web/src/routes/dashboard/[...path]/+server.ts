import { redirect } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = ({ url }) => {
	const target = url.pathname.replace(/^\/dashboard/, '/console') + url.search;
	redirect(308, target);
};
