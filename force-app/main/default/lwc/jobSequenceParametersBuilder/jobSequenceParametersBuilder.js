/**
 * Copyright 2026 Gary Butler
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
/**
 * @description jobSequenceParametersBuilder -- Builds a Sequence Job's Job Parameters (JSON) without writing it by hand:
 * FieldShift field values (typed inputs per field), typed variables used in the query as {!Var.name}, each with an
 * optional value for when Test.isRunningTest() is true, and name/value handler parameters for custom handlers.
 * Renaming a variable renames its tokens in Query - Where. Fires "parameterschange" with { parameters, whereClause }.
 * @author Gary Butler
 * @date 10/17/2026
 */
import { LightningElement, api } from 'lwc';

const NUMBER_FIELD_TYPES = ['INTEGER', 'DOUBLE', 'CURRENCY', 'PERCENT', 'LONG'];
const NAME_PATTERN = /^[A-Za-z][A-Za-z0-9_]{0,39}$/;
const RELATIVE_PATTERN = /^\s*([+-]?\d+)\s*(minute|hour|day|week|month|year)s?\s*$/i;
const DEFAULT_HANDLER = 'JobSequenceDefaultHandler';
const DEFAULT_UNIT = 'days';

const TYPE_OPTIONS = [
    { label: 'Text', value: 'Text' },
    { label: 'Number', value: 'Number' },
    { label: 'Boolean', value: 'Boolean' },
    { label: 'Date', value: 'Date' },
    { label: 'Date/time', value: 'DateTime' },
    { label: 'Relative date', value: 'RelativeDate' },
    { label: 'Relative date/time', value: 'RelativeDateTime' },
    { label: 'Text list (for IN)', value: 'TextList' },
    { label: 'SOQL fragment', value: 'SoqlFragment' }
];
const DATE_UNITS = ['days', 'weeks', 'months', 'years'];
const DATETIME_UNITS = ['minutes', 'hours', 'days', 'weeks', 'months', 'years'];
const TYPE_HELP = {
    Text: 'Inserted as a quoted, escaped string, e.g. \'Closed Lost\'.',
    Number: 'Inserted as a number, e.g. 5.',
    Boolean: 'Inserted as true or false.',
    Date: 'Inserted as a date, e.g. 2026-10-17.',
    DateTime: 'Inserted as a GMT date/time, e.g. 2026-10-17T15:00:00Z.',
    RelativeDate: 'Counted from the day the job runs; negative is the past, e.g. -90 days.',
    RelativeDateTime: 'Counted from when the job runs; negative is the past, e.g. -2 hours.',
    TextList: 'Comma-separated; inserted as (\'A\',\'B\') for use with IN.',
    SoqlFragment: 'Inserted exactly as written, e.g. AND IsActive = true. May be blank.'
};

/**
 * @description Reads a relative amount like "-90 days".
 * @param {String} value The stored value
 * @param {String} fallbackUnit The unit to show when the value has none
 * @returns {Object} { amount, unit } with a plural unit; amount is null when not set
 */
function readRelative(value, fallbackUnit) {
    const match = RELATIVE_PATTERN.exec(value || '');
    return match ? { amount: Number(match[1]), unit: `${match[2].toLowerCase()}s` } : { amount: null, unit: fallbackUnit };
}

/**
 * @description Escapes a string for use in a regular expression.
 * @param {String} text The text
 * @returns {String} The escaped text
 */
function escapeRegExp(text) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

let rowKey = 0;
const nextKey = (prefix) => `${prefix}-${rowKey++}`;

export default class JobSequenceParametersBuilder extends LightningElement {
    @api handlerClass;

    mode = 'builder';
    rawText = '';
    parseError;
    fieldRows = [];
    variableRows = [];
    handlerRows = [];
    // Keys of the JSON the builder doesn't edit, kept as they are
    otherKeys = {};

    _parameters = '';
    _whereClause = '';
    _fieldOptions = [];
    _isFieldShift = false;
    lastEmitted;

    typeOptions = TYPE_OPTIONS;
    booleanOptions = [
        { label: 'true', value: 'true' },
        { label: 'false', value: 'false' }
    ];
    booleanTestOptions = [
        { label: '(same as Value)', value: '' },
        { label: 'true', value: 'true' },
        { label: 'false', value: 'false' }
    ];

    /**
     * @description The Job Parameters JSON. External changes (e.g. loading a job) are read back into the builder.
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

    @api
    get whereClause() {
        return this._whereClause;
    }
    set whereClause(value) {
        this._whereClause = value || '';
    }

    @api
    get fieldOptions() {
        return this._fieldOptions;
    }
    set fieldOptions(value) {
        this._fieldOptions = value || [];
    }

    @api
    get isFieldShift() {
        return this._isFieldShift;
    }
    set isFieldShift(value) {
        this._isFieldShift = Boolean(value);
    }

    // ---------- Reading and writing ----------

    /**
     * @description Reads the JSON into rows. Text that isn't Job Parameters JSON opens in text mode with the error.
     */
    parse() {
        this.parseError = undefined;
        this.rawText = this._parameters;
        let data = {};
        if (this._parameters.trim()) {
            try {
                data = JSON.parse(this._parameters);
                if (data === null || typeof data !== 'object' || Array.isArray(data)) throw new Error('it is not a JSON object');
            } catch (e) {
                this.parseError = `Job Parameters must be JSON, e.g. {"variables": [...]}; ${e.message}. Fix it here, or clear it to start over.`;
                this.mode = 'text';
                return;
            }
        }
        // eslint-disable-next-line no-unused-vars
        const { fieldValues, variables, handlerParameters, version, ...others } = data;
        this.otherKeys = others;
        this.fieldRows = (Array.isArray(fieldValues) ? fieldValues : []).map((fv) => ({
            key: nextKey('field'),
            field: fv?.field || '',
            value: fv?.value ?? '',
            isBlank: fv?.blank === true
        }));
        this.variableRows = (Array.isArray(variables) ? variables : []).map((v) => ({
            key: nextKey('var'),
            name: v?.name || '',
            type: v?.type || 'Text',
            value: v?.value ?? '',
            testValue: v?.testValue ?? ''
        }));
        const params = handlerParameters && typeof handlerParameters === 'object' ? handlerParameters : {};
        this.handlerRows = Object.entries(params).map(([name, value]) => ({ key: nextKey('param'), name, value: value ?? '' }));
    }

    /**
     * @description Builds the JSON from the rows; blank when nothing is set.
     * @returns {String} The Job Parameters JSON
     */
    serialize() {
        const data = { version: 1, ...this.otherKeys };
        const fieldValues = this.fieldRows
            .filter((row) => row.field)
            .map((row) => (row.isBlank ? { field: row.field, blank: true } : { field: row.field, value: row.value ?? '' }));
        const variables = this.variableRows.map((row) => {
            const variable = { name: row.name, type: row.type };
            if (row.value !== '' && row.value !== null) variable.value = row.value;
            if (row.testValue !== '' && row.testValue !== null) variable.testValue = row.testValue;
            return variable;
        });
        const handlerParameters = {};
        this.handlerRows
            .filter((row) => row.name)
            .forEach((row) => {
                handlerParameters[row.name] = row.value ?? '';
            });
        if (fieldValues.length) data.fieldValues = fieldValues;
        if (variables.length) data.variables = variables;
        if (Object.keys(handlerParameters).length) data.handlerParameters = handlerParameters;
        return Object.keys(data).length > 1 ? JSON.stringify(data, null, 2) : '';
    }

    /**
     * @description Sends the parameters (and the Where, which a rename may have changed) to the editor.
     */
    emit() {
        const parameters = this.mode === 'text' ? this.rawText : this.serialize();
        this.lastEmitted = parameters;
        this._parameters = parameters;
        this.dispatchEvent(new CustomEvent('parameterschange', { detail: { parameters, whereClause: this._whereClause } }));
    }

    // ---------- Checks ----------

    /**
     * @description Problems with the variable names, and variables Query - Where uses but doesn't define. The
     * editor's Built query panel lists the full checks from the server.
     * @returns {String[]} The problems
     */
    get variableProblems() {
        const problems = [];
        const seen = new Set();
        this.variableRows.forEach((row) => {
            if (!NAME_PATTERN.test(row.name)) {
                problems.push(`Variable name "${row.name}" must start with a letter and use only letters, numbers and underscores.`);
            } else if (seen.has(row.name.toLowerCase())) {
                problems.push(`Two variables are named ${row.name}.`);
            }
            seen.add(row.name.toLowerCase());
        });
        for (const [, name] of this._whereClause.matchAll(/\{!\s*Var\.([A-Za-z0-9_]+)\s*\}/gi)) {
            if (!seen.has(name.toLowerCase())) problems.push(`Query - Where uses {!Var.${name}}, but no variable named ${name} is defined.`);
        }
        return [...new Set(problems)];
    }

    get hasVariableProblems() {
        return this.variableProblems.length > 0;
    }

    // ---------- Display ----------

    get isBuilderMode() {
        return this.mode === 'builder';
    }

    get modeToggleLabel() {
        return this.isBuilderMode ? 'Edit as text' : 'Back to the builder';
    }

    get generatedText() {
        return this._parameters;
    }

    get hasGeneratedText() {
        return Boolean(this.generatedText);
    }

    get showFieldValues() {
        return this._isFieldShift || this.fieldRows.length > 0;
    }

    get fieldValuesIgnored() {
        return !this._isFieldShift && this.fieldRows.length > 0;
    }

    get showHandlerParameters() {
        return Boolean(this.handlerClass && this.handlerClass !== DEFAULT_HANDLER) || this.handlerRows.length > 0;
    }

    get noFieldsYet() {
        return !this._fieldOptions.some((f) => f.kind === 'field');
    }

    get updateableFieldOptions() {
        return this._fieldOptions.filter((f) => f.kind === 'field' && f.updateable);
    }

    get fieldsByLowerName() {
        const map = new Map();
        this._fieldOptions.filter((f) => f.kind === 'field').forEach((f) => map.set(f.value.toLowerCase(), f));
        return map;
    }

    /**
     * @description The field value rows with what each needs to render its value input.
     * @returns {Object[]} The display rows
     */
    get displayFieldRows() {
        const fields = this.fieldsByLowerName;
        return this.fieldRows.map((row) => {
            const field = row.field ? fields.get(row.field.toLowerCase()) : undefined;
            const type = field?.fieldType || 'STRING';
            // A token such as {!Today} can't go in a typed input, so it is shown as text
            const typed = !String(row.value).includes('{!');
            const hasPicklistValues = (type === 'PICKLIST' || type === 'MULTIPICKLIST') && Boolean(field?.picklistValues?.length);
            return {
                ...row,
                fieldLabel: field ? `${field.label} (${field.value})` : row.field,
                isCheckbox: typed && type === 'BOOLEAN',
                checked: String(row.value).toLowerCase() === 'true',
                isDate: typed && type === 'DATE',
                isDateTime: typed && type === 'DATETIME',
                isNumber: typed && NUMBER_FIELD_TYPES.includes(type),
                isPicklist: typed && hasPicklistValues,
                picklistOptions: (field?.picklistValues || []).map((v) => ({ label: v, value: v })),
                excludeFields: this.fieldRows.filter((r) => r.key !== row.key && r.field).map((r) => r.field)
            };
        });
    }

    /**
     * @description The variable rows with the inputs their type needs, for the value and the test value.
     * @returns {Object[]} The display rows
     */
    get displayVariableRows() {
        return this.variableRows.map((row) => {
            const isRelativeDate = row.type === 'RelativeDate';
            const relativeValue = readRelative(row.value, DEFAULT_UNIT);
            const relativeTest = readRelative(row.testValue, relativeValue.unit);
            return {
                ...row,
                token: NAME_PATTERN.test(row.name) ? `{!Var.${row.name}}` : '',
                typeHelp: TYPE_HELP[row.type],
                isRelative: isRelativeDate || row.type === 'RelativeDateTime',
                isBoolean: row.type === 'Boolean',
                isNumber: row.type === 'Number',
                isDate: row.type === 'Date',
                isDateTime: row.type === 'DateTime',
                isText: ['Text', 'TextList', 'SoqlFragment'].includes(row.type) || !TYPE_HELP[row.type],
                textPlaceholder: row.type === 'TextList' ? 'A, B' : row.type === 'SoqlFragment' ? 'AND IsActive = true' : '',
                units: (isRelativeDate ? DATE_UNITS : DATETIME_UNITS).map((u) => ({ label: u, value: u })),
                valueAmount: relativeValue.amount,
                valueUnit: relativeValue.unit,
                testAmount: relativeTest.amount,
                testUnit: relativeTest.unit
            };
        });
    }

    // ---------- Handlers: mode ----------

    handleToggleMode() {
        if (this.isBuilderMode) {
            this.rawText = this.serialize();
            this.mode = 'text';
        } else {
            this._parameters = this.rawText;
            this.mode = 'builder';
            this.parse();
            if (this.isBuilderMode) this.emit();
        }
    }

    handleRawChange(event) {
        this.rawText = event.detail.value;
        this.parseError = undefined;
        this.emit();
    }

    // ---------- Handlers: field values ----------

    handleAddField() {
        this.fieldRows = [...this.fieldRows, { key: nextKey('field'), field: '', value: '', isBlank: false }];
    }

    updateField(key, changes) {
        this.fieldRows = this.fieldRows.map((row) => (row.key === key ? { ...row, ...changes } : row));
        this.emit();
    }

    handleFieldName(event) {
        this.updateField(event.target.dataset.key, { field: event.detail.value, value: '' });
    }

    handleFieldValue(event) {
        const value = event.target.type === 'checkbox' ? String(event.target.checked) : event.detail.value ?? event.target.value;
        this.updateField(event.target.dataset.key, { value });
    }

    handleFieldBlank(event) {
        this.updateField(event.target.dataset.key, { isBlank: event.target.checked });
    }

    handleRemoveField(event) {
        this.fieldRows = this.fieldRows.filter((row) => row.key !== event.currentTarget.dataset.key);
        this.emit();
    }

    // ---------- Handlers: variables ----------

    handleAddVariable() {
        const names = new Set(this.variableRows.map((r) => r.name.toLowerCase()));
        let n = this.variableRows.length + 1;
        while (names.has(`var${n}`)) n++;
        this.variableRows = [...this.variableRows, { key: nextKey('var'), name: `var${n}`, type: 'RelativeDateTime', value: '', testValue: '' }];
        this.emit();
    }

    updateVariable(key, changes) {
        this.variableRows = this.variableRows.map((row) => (row.key === key ? { ...row, ...changes } : row));
        this.emit();
    }

    /**
     * @description Renames a variable, and its {!Var.name} tokens in Query - Where.
     * @param {Event} event The name input's change event
     */
    handleVariableName(event) {
        const key = event.target.dataset.key;
        const newName = (event.detail.value || '').trim();
        const oldName = this.variableRows.find((r) => r.key === key)?.name;
        if (oldName && NAME_PATTERN.test(oldName) && NAME_PATTERN.test(newName) && oldName !== newName) {
            const token = new RegExp(`\\{!\\s*Var\\.${escapeRegExp(oldName)}\\s*\\}`, 'gi');
            this._whereClause = this._whereClause.replace(token, `{!Var.${newName}}`);
        }
        this.updateVariable(key, { name: newName });
    }

    handleVariableType(event) {
        // Values rarely fit a new type, so they are cleared
        this.updateVariable(event.target.dataset.key, { type: event.detail.value, value: '', testValue: '' });
    }

    /**
     * @description Sets a variable's value or test value (data-part), including the amount or unit (data-sub) of a
     * relative one, which is stored as e.g. "-90 days".
     * @param {Event} event The input's change event
     */
    handleVariableValue(event) {
        const { key, part, sub } = event.target.dataset;
        const row = this.variableRows.find((r) => r.key === key);
        let value = event.detail.value ?? '';
        if (sub) {
            const fallbackUnit = part === 'testValue' ? readRelative(row.value, DEFAULT_UNIT).unit : DEFAULT_UNIT;
            const current = readRelative(row[part], fallbackUnit);
            const amount = sub === 'amount' ? value : current.amount;
            const unit = sub === 'unit' ? value : current.unit;
            value = amount === '' || amount === null || amount === undefined ? '' : `${Number(amount)} ${unit}`;
        }
        this.updateVariable(key, { [part]: value });
    }

    handleRemoveVariable(event) {
        this.variableRows = this.variableRows.filter((row) => row.key !== event.currentTarget.dataset.key);
        this.emit();
    }

    // ---------- Handlers: handler parameters ----------

    handleAddHandlerParameter() {
        this.handlerRows = [...this.handlerRows, { key: nextKey('param'), name: '', value: '' }];
    }

    handleHandlerParameter(event) {
        const { key, part } = event.target.dataset;
        this.handlerRows = this.handlerRows.map((row) => (row.key === key ? { ...row, [part]: event.detail.value } : row));
        this.emit();
    }

    handleRemoveHandlerParameter(event) {
        this.handlerRows = this.handlerRows.filter((row) => row.key !== event.currentTarget.dataset.key);
        this.emit();
    }
}
