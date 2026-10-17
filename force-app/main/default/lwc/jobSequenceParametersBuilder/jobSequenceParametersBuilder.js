/**
 * @description jobSequenceParametersBuilder -- Builds a Sequence Job's Job Parameters without learning their syntax:
 * FieldShift field values (typed inputs per field) and variable rows for the two variables the engine supports,
 * DateTimeVar (used as :DateTimeVar) and swap-in text (used as {0}), each with a value for scheduled runs or for when
 * Test.isRunningTest() is true. It reads existing parameters back into rows and keeps anything it doesn't recognize.
 * The Where is never rewritten; variables are inserted with the editor's field chooser. Fires "parameterschange" with
 * { parameters, whereClause }.
 * @author Gary Butler
 * @date 10/17/2026
 */
import { LightningElement, api } from 'lwc';

const TEST_KEY = 'test.isrunningtest';
const NOT_TEST_KEY = '!test.isrunningtest';
const DATETIME_VAR = /^DateTimeVar\s*=\s*(-?\d+)$/i;
const NUMBER_TYPES = ['INTEGER', 'DOUBLE', 'CURRENCY', 'PERCENT', 'LONG'];
const UNIT_MINUTES = { minutes: 1, hours: 60, days: 1440 };
const VARIABLE_DATETIME = 'DateTimeVar';
const VARIABLE_SWAP = '{0}';

/**
 * @description Splits Job Parameters text on commas outside double quotes, the way the engine does.
 * @param {String} text The parameters text
 * @returns {String[]} The trimmed, non-blank entries
 */
function splitParameters(text) {
    const entries = [];
    let inQuotes = false;
    let current = '';
    for (const ch of (text || '').replace(/[\r\n]+/g, '')) {
        if (ch === '"') inQuotes = !inQuotes;
        if (ch === ',' && !inQuotes) {
            if (current.trim()) entries.push(current.trim());
            current = '';
        } else {
            current += ch;
        }
    }
    if (current.trim()) entries.push(current.trim());
    return entries;
}

/**
 * @description Removes one pair of surrounding double quotes, as the engine does.
 * @param {String} value The value
 * @returns {String} The value without its quotes
 */
function unquote(value) {
    let v = (value || '').trim();
    if (v.startsWith('"')) v = v.slice(1);
    if (v.endsWith('"')) v = v.slice(0, -1);
    return v;
}

/**
 * @description Picks the largest whole unit (days, hours or minutes) for a signed number of minutes.
 * @param {Number} minutes The minutes (negative is the past)
 * @returns {Object} { amount, unit } with the sign kept on the amount
 */
function toAmount(minutes) {
    const m = Math.abs(minutes);
    const sign = minutes < 0 ? -1 : 1;
    if (m && m % 1440 === 0) return { amount: (sign * m) / 1440, unit: 'days' };
    if (m && m % 60 === 0) return { amount: (sign * m) / 60, unit: 'hours' };
    return { amount: minutes, unit: 'minutes' };
}

let rowKey = 0;

export default class JobSequenceParametersBuilder extends LightningElement {
    mode = 'builder';
    rawText = '';
    fieldRows = [];
    variableRows = [];
    otherEntries = [];

    _parameters = '';
    _isFieldShift = false;
    _whereClause = '';
    _fieldOptions = [];
    lastEmitted;

    variableOptions = [
        { label: 'DateTimeVar (relative date/time, used as :DateTimeVar)', value: VARIABLE_DATETIME },
        { label: 'Swap-in text (used as {0})', value: VARIABLE_SWAP }
    ];
    swapTextHelp = 'Replaces {0} in Query - Where, so usually starts with AND or OR.';
    unitOptions = [
        { label: 'minutes', value: 'minutes' },
        { label: 'hours', value: 'hours' },
        { label: 'days', value: 'days' }
    ];

    /**
     * @description The Job Parameters text. External changes (e.g. loading a job) are read back into the builder.
     */
    @api
    get parameters() {
        return this._parameters;
    }
    set parameters(value) {
        this._parameters = value || '';
        if (this._parameters !== this.lastEmitted) {
            this.parse();
        }
    }

    /**
     * @description Whether the job runs FieldShift. Only FieldShift reads field values, so other jobs keep
     * field-named entries under Other parameters; the parameters are re-read when this changes.
     */
    @api
    get isFieldShift() {
        return this._isFieldShift;
    }
    set isFieldShift(value) {
        const changed = Boolean(value) !== this._isFieldShift;
        this._isFieldShift = Boolean(value);
        if (changed && this.mode === 'builder') this.parse();
    }

    @api
    get whereClause() {
        return this._whereClause;
    }
    set whereClause(value) {
        this._whereClause = value || '';
    }

    /**
     * @description The object's fields; when they arrive, the parameters are re-read so field values are recognized.
     */
    @api
    get fieldOptions() {
        return this._fieldOptions;
    }
    set fieldOptions(value) {
        this._fieldOptions = value || [];
        if (this.mode === 'builder') this.parse();
    }

    // ---------- Reading parameters into rows ----------

    get fieldsByLowerName() {
        const map = new Map();
        this._fieldOptions.filter((f) => f.kind === 'field').forEach((f) => map.set(f.value.toLowerCase(), f));
        return map;
    }

    /**
     * @description Reads the parameters text into field rows, variable rows and anything else.
     */
    parse() {
        const fields = this.fieldsByLowerName;
        const fieldRows = [];
        const variableRows = [];
        const other = [];
        splitParameters(this._parameters).forEach((entry) => {
            const colon = entry.indexOf(':');
            if (colon < 1) {
                other.push(entry);
                return;
            }
            const name = unquote(entry.slice(0, colon)).trim();
            const value = unquote(entry.slice(colon + 1));
            const key = name.toLowerCase();
            if (key === TEST_KEY || key === NOT_TEST_KEY) {
                const isTest = key === TEST_KEY;
                const match = DATETIME_VAR.exec(value);
                if (match) {
                    const { amount, unit } = toAmount(Number(match[1]));
                    variableRows.push({ key: `var-${rowKey++}`, variable: VARIABLE_DATETIME, isTest, amount, unit, text: '' });
                } else {
                    variableRows.push({ key: `var-${rowKey++}`, variable: VARIABLE_SWAP, isTest, amount: null, unit: 'days', text: value });
                }
            } else if (this._isFieldShift && fields.has(key)) {
                const isBlank = value.toLowerCase() === 'null';
                fieldRows.push({ key: `row-${rowKey++}`, field: fields.get(key).value, value: isBlank ? '' : value, isBlank });
            } else {
                other.push(entry);
            }
        });
        this.fieldRows = fieldRows;
        this.variableRows = variableRows;
        this.otherEntries = other;
        this.rawText = this._parameters;
    }

    // ---------- Writing rows back to parameters ----------

    /**
     * @description Builds the parameters text from the rows, in the format the engine reads.
     * @returns {String} The Job Parameters text, one entry per line
     */
    serialize() {
        const entries = [];
        if (this._isFieldShift) {
            this.fieldRows
                .filter((row) => row.field)
                .forEach((row) => entries.push(`${row.field}:"${row.isBlank ? 'null' : row.value ?? ''}"`));
        }
        this.variableRows.forEach((row) => {
            const prefix = row.isTest ? 'Test.isRunningTest' : '!Test.isRunningTest';
            if (row.variable === VARIABLE_DATETIME) {
                const minutes = this.minutesFor(row);
                if (minutes !== null) entries.push(`${prefix}:"DateTimeVar=${minutes}"`);
            } else if (row.variable === VARIABLE_SWAP && (row.text || '').trim()) {
                entries.push(`${prefix}:"${row.text.trim()}"`);
            }
        });
        return [...entries, ...this.otherEntries].join(',\n');
    }

    minutesFor(row) {
        if (row.amount === null || row.amount === '' || Number.isNaN(Number(row.amount))) return null;
        return Math.round(Number(row.amount) * UNIT_MINUTES[row.unit]);
    }

    /**
     * @description Sends the new parameters to the editor. The Where is passed through unchanged.
     */
    emit() {
        const parameters = this.mode === 'text' ? this.rawText : this.serialize();
        this.lastEmitted = parameters;
        this._parameters = parameters;
        this.dispatchEvent(new CustomEvent('parameterschange', { detail: { parameters, whereClause: this._whereClause } }));
    }

    // ---------- Checks ----------

    /**
     * @description Problems with the variable rows: two rows for the same context, mixed variable types, or a
     * DateTimeVar row without an amount.
     * @returns {String[]} The problems
     */
    get variableProblems() {
        const problems = [];
        const scheduled = this.variableRows.filter((r) => !r.isTest);
        const testing = this.variableRows.filter((r) => r.isTest);
        if (scheduled.length > 1) problems.push('Only one variable row can be for scheduled runs (Test.isRunningTest() unchecked).');
        if (testing.length > 1) problems.push('Only one variable row can be for when Test.isRunningTest() is true.');
        const types = new Set(this.variableRows.map((r) => r.variable));
        if (types.size > 1) problems.push('A job can use DateTimeVar or swap-in text {0}, not both.');
        if (this.variableRows.some((r) => r.variable === VARIABLE_DATETIME && this.minutesFor(r) === null)) {
            problems.push('Enter an amount for each DateTimeVar row.');
        }
        return problems;
    }

    get hasVariableProblems() {
        return this.variableProblems.length > 0;
    }

    /**
     * @description Explains when the Where and the variable rows don't match.
     * @returns {String} The warning, or undefined
     */
    get whereWarning() {
        const where = this._whereClause || '';
        const usesDateTime = /:\s*(g_)?DateTimeVar\b/i.test(where);
        const usesSwap = where.includes('{0}');
        const types = new Set(this.variableRows.map((r) => r.variable));
        if (types.has(VARIABLE_DATETIME) && !usesDateTime) {
            return 'DateTimeVar is defined, but Query - Where has no :DateTimeVar. Click in Query - Where and insert it from the field chooser.';
        }
        if (types.has(VARIABLE_SWAP) && !usesSwap) {
            return 'Swap-in text is defined, but Query - Where has no {0}. Click in Query - Where and insert it from the field chooser.';
        }
        if (usesDateTime && !types.has(VARIABLE_DATETIME)) {
            return 'Query - Where uses :DateTimeVar, but no DateTimeVar variable is defined. Add a variable row for it.';
        }
        return undefined;
    }

    // ---------- Display ----------

    get isBuilderMode() {
        return this.mode === 'builder';
    }

    get modeToggleLabel() {
        return this.isBuilderMode ? 'Edit as text' : 'Back to the builder';
    }

    // The job's actual parameters; every builder change is written to them, so this is also what the builder produced
    get generatedText() {
        return this._parameters;
    }

    get hasGeneratedText() {
        return Boolean(this.generatedText);
    }

    get hasOtherEntries() {
        return this.otherEntries.length > 0;
    }

    get otherText() {
        return this.otherEntries.join(',\n');
    }

    get noFieldsYet() {
        return !this._fieldOptions.some((f) => f.kind === 'field');
    }

    get updateableFieldOptions() {
        return this._fieldOptions.filter((f) => f.kind === 'field' && f.updateable);
    }

    get displayVariableRows() {
        return this.variableRows.map((row) => ({
            ...row,
            isDateTime: row.variable === VARIABLE_DATETIME,
            isSwap: row.variable === VARIABLE_SWAP
        }));
    }

    /**
     * @description The FieldShift rows with what each needs to render its value input.
     * @returns {Object[]} The display rows
     */
    get displayRows() {
        const fields = this.fieldsByLowerName;
        return this.fieldRows.map((row) => {
            const field = row.field ? fields.get(row.field.toLowerCase()) : undefined;
            const type = field?.fieldType || 'STRING';
            const hasPicklistValues = (type === 'PICKLIST' || type === 'MULTIPICKLIST') && Boolean(field?.picklistValues?.length);
            return {
                ...row,
                fieldLabel: field ? `${field.label} (${field.value})` : row.field,
                isCheckbox: type === 'BOOLEAN',
                checked: String(row.value).toLowerCase() === 'true',
                isDate: type === 'DATE',
                isDateTime: type === 'DATETIME',
                isNumber: NUMBER_TYPES.includes(type),
                // A picklist without active values falls back to a text input
                isPicklist: hasPicklistValues,
                picklistOptions: (field?.picklistValues || []).map((v) => ({ label: v, value: v })),
                valueDisabled: row.isBlank,
                excludeFields: this.fieldRows.filter((r) => r.key !== row.key && r.field).map((r) => r.field)
            };
        });
    }

    // ---------- Handlers ----------

    handleToggleMode() {
        if (this.isBuilderMode) {
            this.rawText = this.serialize();
            this.mode = 'text';
        } else {
            this._parameters = this.rawText;
            this.mode = 'builder';
            this.parse();
            this.emit();
        }
    }

    handleRawChange(event) {
        this.rawText = event.detail.value;
        this.emit();
    }

    // Field rows
    handleAddRow() {
        this.fieldRows = [...this.fieldRows, { key: `row-${rowKey++}`, field: '', value: '', isBlank: false }];
    }

    updateRow(key, changes) {
        this.fieldRows = this.fieldRows.map((row) => (row.key === key ? { ...row, ...changes } : row));
        this.emit();
    }

    handleRowField(event) {
        this.updateRow(event.target.dataset.key, { field: event.detail.value, value: '' });
    }

    handleRowValue(event) {
        const key = event.target.dataset.key;
        const value = event.target.type === 'checkbox' ? String(event.target.checked) : event.detail.value ?? event.target.value;
        this.updateRow(key, { value });
    }

    handleRowBlank(event) {
        this.updateRow(event.target.dataset.key, { isBlank: event.target.checked });
    }

    handleRemoveRow(event) {
        this.fieldRows = this.fieldRows.filter((row) => row.key !== event.currentTarget.dataset.key);
        this.emit();
    }

    // Variable rows
    handleAddVariable() {
        // Suggest the context and variable that aren't used yet
        const hasScheduled = this.variableRows.some((r) => !r.isTest);
        const variable = this.variableRows[0]?.variable || VARIABLE_DATETIME;
        this.variableRows = [
            ...this.variableRows,
            { key: `var-${rowKey++}`, variable, isTest: hasScheduled, amount: null, unit: 'days', text: '' }
        ];
    }

    updateVariable(key, changes) {
        this.variableRows = this.variableRows.map((row) => (row.key === key ? { ...row, ...changes } : row));
        this.emit();
    }

    handleVariableName(event) {
        this.updateVariable(event.target.dataset.key, { variable: event.detail.value });
    }

    handleVariableTest(event) {
        this.updateVariable(event.target.dataset.key, { isTest: event.target.checked });
    }

    handleVariableAmount(event) {
        const value = event.detail.value;
        this.updateVariable(event.target.dataset.key, { amount: value === '' || value === null ? null : Number(value) });
    }

    handleVariableUnit(event) {
        this.updateVariable(event.target.dataset.key, { unit: event.detail.value });
    }

    handleVariableText(event) {
        this.updateVariable(event.target.dataset.key, { text: event.detail.value });
    }

    handleRemoveVariable(event) {
        this.variableRows = this.variableRows.filter((row) => row.key !== event.currentTarget.dataset.key);
        this.emit();
    }

    handleOtherChange(event) {
        this.otherEntries = splitParameters(event.detail.value);
        this.emit();
    }
}
