export type EditorDialogMode = 'create' | 'edit';

export type EditorDialogValues = Record<string, unknown>;

export type EditorDialogValidate = (value: unknown, allValues: EditorDialogValues) => string | null;

export type EditorDialogVisible = (allValues: EditorDialogValues) => boolean;

export type EditorDialogSelectOption = {
	value: string;
	label: string;
	description?: string;
};

type EditorDialogFieldBase<TType extends string> = {
	type: TType;
	name: string;
	label: string;
	helpText?: string;
	required?: boolean;
	validate?: EditorDialogValidate;
	visible?: EditorDialogVisible;
};

export type EditorDialogTextFieldSchema = EditorDialogFieldBase<'text'> & {
	placeholder?: string;
	maxLength?: number;
	pattern?: string;
};

export type EditorDialogTextareaFieldSchema = EditorDialogFieldBase<'textarea'> & {
	rows?: number;
	maxLength?: number;
};

export type EditorDialogSelectFieldSchema = EditorDialogFieldBase<'select'> & {
	options: EditorDialogSelectOption[];
};

export type EditorDialogMultiselectFieldSchema = EditorDialogFieldBase<'multiselect'> & {
	options: EditorDialogSelectOption[];
	minItems?: number;
	maxItems?: number;
};

export type EditorDialogNumberFieldSchema = EditorDialogFieldBase<'number'> & {
	min?: number;
	max?: number;
	step?: number;
	integer?: boolean;
};

export type EditorDialogToggleFieldSchema = EditorDialogFieldBase<'toggle'> & {
	default?: boolean;
};

export type EditorDialogRadioFieldSchema = EditorDialogFieldBase<'radio'> & {
	options: EditorDialogSelectOption[];
};

export type EditorDialogDateTimeLocalFieldSchema = EditorDialogFieldBase<'datetime-local'> & {
	min?: string;
	max?: string;
};

export type EditorDialogSimpleFieldSchema =
	| EditorDialogTextFieldSchema
	| EditorDialogTextareaFieldSchema
	| EditorDialogSelectFieldSchema
	| EditorDialogMultiselectFieldSchema
	| EditorDialogNumberFieldSchema
	| EditorDialogToggleFieldSchema
	| EditorDialogRadioFieldSchema
	| EditorDialogDateTimeLocalFieldSchema;

export type EditorDialogGroupFieldSchema = {
	type: 'group';
	fields: EditorDialogSimpleFieldSchema[];
};

export type EditorDialogArrayFieldSchema = EditorDialogFieldBase<'array'> & {
	item: EditorDialogSimpleFieldSchema | EditorDialogGroupFieldSchema;
	addLabel: string;
	minItems?: number;
	maxItems?: number;
};

export type EditorDialogFieldSchema = EditorDialogSimpleFieldSchema | EditorDialogArrayFieldSchema;

export type EditorDialogSaveRejection = {
	message?: string;
	fieldErrors?: Record<string, string>;
};

export type EditorDialogOnSave = (value: EditorDialogValues) => Promise<void>;

export type EditorDialogProps = {
	title: string;
	mode: EditorDialogMode;
	schema: EditorDialogFieldSchema[];
	initialValue: EditorDialogValues;
	open: boolean;
	onSave: EditorDialogOnSave;
	onCancel: () => void;
	description?: string;
	submitLabel?: string;
	testId?: string;
};

const EDITOR_DIALOG_ARRAY_FIELD_TEST_ID_PREFIX = 'editor-dialog-field';

export function editorDialogArrayItemTestId(arrayName: string, index: number): string {
	return `${EDITOR_DIALOG_ARRAY_FIELD_TEST_ID_PREFIX}-${arrayName}-${index}`;
}

export function editorDialogArrayGroupItemFieldTestId(
	arrayName: string,
	index: number,
	fieldName: string
): string {
	return `${editorDialogArrayItemTestId(arrayName, index)}-${fieldName}`;
}

export function editorDialogArrayGroupItemFieldOptionTestId(
	arrayName: string,
	index: number,
	fieldName: string,
	optionValue: string
): string {
	return `${editorDialogArrayGroupItemFieldTestId(arrayName, index, fieldName)}-${optionValue}`;
}
