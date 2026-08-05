export function formDataString(data: FormData, fieldName: string): string {
	const value = data.get(fieldName);
	return typeof value === 'string' ? value : '';
}
