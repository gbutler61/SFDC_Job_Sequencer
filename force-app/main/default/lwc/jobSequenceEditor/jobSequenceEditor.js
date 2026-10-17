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
 * @description jobSequenceEditor -- Modal for creating, cloning and editing a Sequence Job. Tests the job's query and
 * saves the record through JobSequenceManagerController, waiting for the asynchronous deployment to finish.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { api, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import saveSequenceJob from '@salesforce/apex/JobSequenceManagerController.saveSequenceJob';
import testQuery from '@salesforce/apex/JobSequenceManagerController.testQuery';
import getObjectOptions from '@salesforce/apex/JobSequenceManagerController.getObjectOptions';
import getObjectFields from '@salesforce/apex/JobSequenceManagerController.getObjectFields';
import getHandlerOptions from '@salesforce/apex/JobSequenceManagerController.getHandlerOptions';
import buildQuery from '@salesforce/apex/JobSequenceManagerController.buildQuery';
import { ensureSubscribed, waitForDeployment } from 'c/jobSequenceDeployWatcher';

const NUMBER_FIELDS = ['batchLimit', 'recordLimit'];
const OTHER_FUNCTION = '__other__';
// Shown in the editor footer while testing, to confirm the browser has the latest version; bumped on each deploy
const BUILD_NUMBER = 7;
const QUERY_FIELD_LABELS = { selectFields: 'Query - Select', whereClause: 'Query - Where', orderBy: 'Query - OrderBy' };
const CHECKBOX_FIELDS = ['active', 'isBatchJob', 'permDelete', 'allOrNone'];
const DML_OPTIONS = [
    { label: 'UPDATE', value: 'UPDATE' },
    { label: 'DELETE', value: 'DELETE' }
];

/**
 * @description Pulls a readable message out of an Apex error.
 * @param {Object} error The error returned by an imperative Apex call
 * @returns {String} The message to show the user
 */
function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Unknown error';
}

/**
 * @description Splits a SELECT list on top-level commas, so subqueries in parentheses stay whole.
 * @param {String} text The SELECT list
 * @returns {String[]} The trimmed items
 */
function splitSelectList(text) {
    const items = [];
    let depth = 0;
    let current = '';
    for (const ch of text || '') {
        if (ch === '(') depth++;
        if (ch === ')') depth = Math.max(0, depth - 1);
        if (ch === ',' && depth === 0) {
            items.push(current.trim());
            current = '';
        } else {
            current += ch;
        }
    }
    items.push(current.trim());
    return items.filter((item) => item);
}

// Top-level SOQL clause keywords, longest first so "ORDER BY" wins over shorter matches
const SOQL_KEYWORDS = ['USING SCOPE', 'GROUP BY', 'ORDER BY', 'SELECT', 'HAVING', 'OFFSET', 'WHERE', 'LIMIT', 'FROM', 'WITH', 'FOR'];
const UNSUPPORTED_CLAUSES = ['GROUP BY', 'HAVING', 'OFFSET', 'USING SCOPE'];

/**
 * @description Finds the clause keywords that are at the top level of a query: not inside parentheses (subqueries,
 * function calls) or quoted strings.
 * @param {String} text The query, with whitespace collapsed
 * @returns {Object[]} The keywords found, in order: { keyword, index }
 */
function findTopLevelClauses(text) {
    const upper = text.toUpperCase();
    const hits = [];
    let depth = 0;
    let inQuote = false;
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (inQuote) {
            if (ch === '\\') i++;
            else if (ch === "'") inQuote = false;
            continue;
        }
        if (ch === "'") {
            inQuote = true;
            continue;
        }
        if (ch === '(') {
            depth++;
            continue;
        }
        if (ch === ')') {
            depth = Math.max(0, depth - 1);
            continue;
        }
        if (depth > 0 || (i > 0 && /[A-Za-z0-9_.]/.test(text[i - 1]))) continue;
        const keyword = SOQL_KEYWORDS.find((kw) => upper.startsWith(kw, i) && (i + kw.length === text.length || /[\s(]/.test(text[i + kw.length])));
        if (keyword) {
            hits.push({ keyword, index: i });
            i += keyword.length - 1;
        }
    }
    return hits;
}

/**
 * @description Splits a SOQL query into the parts a Sequence Job holds.
 * @param {String} query The pasted query
 * @returns {Object} { select, from, where, orderBy, limit, notes[] } or { error }
 */
function parseSoql(query) {
    const text = (query || '').replace(/\s+/g, ' ').trim().replace(/;$/, '').trim();
    if (!text) return { error: 'Paste a query first.' };
    const hits = findTopLevelClauses(text);
    if (!hits.length || hits[0].keyword !== 'SELECT' || hits[0].index !== 0) {
        return { error: 'The query must start with SELECT.' };
    }
    const clauses = {};
    hits.forEach((hit, n) => {
        const end = n + 1 < hits.length ? hits[n + 1].index : text.length;
        if (clauses[hit.keyword] === undefined) {
            clauses[hit.keyword] = text.slice(hit.index + hit.keyword.length, end).trim();
        }
    });

    const unsupported = UNSUPPORTED_CLAUSES.filter((kw) => clauses[kw] !== undefined);
    if (unsupported.length) {
        return { error: `${unsupported.join(', ')} can't be used in a sequence job query.` };
    }
    if (!clauses.FROM) return { error: 'The query has no FROM object.' };
    if (!clauses.SELECT) return { error: 'The query has no fields after SELECT.' };

    const notes = [];
    if (clauses.WITH !== undefined) notes.push(`WITH ${clauses.WITH} was dropped; sequence jobs always run in system mode.`);
    if (clauses.FOR !== undefined) notes.push(`FOR ${clauses.FOR} was dropped.`);

    let limit = null;
    if (clauses.LIMIT !== undefined) {
        limit = Number.parseInt(clauses.LIMIT, 10);
        if (!Number.isInteger(limit) || limit < 1) {
            return { error: `LIMIT ${clauses.LIMIT} isn't a whole number; use a number, not a bind variable.` };
        }
    }

    let where = clauses.WHERE;
    if (!where) {
        where = 'Id != null';
        notes.push('The query had no WHERE, so Id != null was used (batch jobs need a WHERE).');
    }
    if (/:\s*[A-Za-z_]/.test(where.replace(/'[^']*'/g, ''))) {
        notes.push('The WHERE uses a bind variable (:name), which a sequence job can\'t supply. Define a variable in Job Parameters and use {!Var.name} instead.');
    }

    return {
        select: clauses.SELECT,
        // Only the object name; an alias after it isn't used by sequence jobs
        from: clauses.FROM.split(' ')[0],
        where,
        orderBy: clauses['ORDER BY'] || null,
        limit,
        notes
    };
}

/**
 * @description Suggests an API name from a label: letters, numbers and single underscores, starting with a letter.
 * @param {String} label The label
 * @returns {String} The suggested API name
 */
function toDeveloperName(label) {
    let name = (label || '')
        .toUpperCase()
        .replace(/[^A-Z0-9]+/g, '_')
        .replace(/^_+|_+$/g, '');
    if (name && !/^[A-Z]/.test(name)) {
        name = `JOB_${name}`;
    }
    return name.substring(0, 40).replace(/_+$/, '');
}

/**
 * @description Reads Job Parameters JSON.
 * @param {String} text The parameters
 * @returns {Object} The parsed parameters, or an empty object when blank or not valid JSON
 */
function parseJobParameters(text) {
    try {
        const data = text && text.trim() ? JSON.parse(text) : {};
        return data && typeof data === 'object' && !Array.isArray(data) ? data : {};
    } catch (e) {
        return {};
    }
}

// Tokens offered in the Where chooser besides the job's own variables
const BUILT_IN_TOKENS = [
    { label: '{!Now}', value: '{!Now}', detail: 'When the job runs, as a GMT date/time' },
    { label: '{!Today}', value: '{!Today}', detail: 'The day the job runs (GMT)' },
    { label: '{!UserId}', value: '{!UserId}', detail: 'The Id of the user who scheduled the job, quoted' }
];

export default class JobSequenceEditor extends LightningModal {
    @api job;
    @api isNew = false;
    @api frequencyOptions = [];
    @api jobTypeOptions = [];

    form = {};
    developerNameEdited = false;
    showQueryErrors = false;
    testAsUnitTestChoice;
    builtQuery;
    previewTimer;
    insertTarget = 'selectFields';
    chooserOpen = false;
    chooserHasFocus = false;
    queryBoxHasFocus = false;
    closeChooserTimer;
    cursorPositions = {};
    showPasteQuery = false;
    pastedQuery = '';
    pasteError;
    pasteNotes;
    errorLines;
    isSaving = false;
    isTesting = false;
    queryResult;
    objectOptions = [];
    handlerOptions = [];
    typingFunction = false;
    fieldOptions = [];
    fieldsObject;

    dmlOptions = DML_OPTIONS;
    buildNumber = BUILD_NUMBER;
    // Braces can't be written literally in a template attribute, so this help text is bound from here
    whereHelp = 'Do not include WHERE. Settings tokens such as {!Settings.RunRetentionDays__c} are replaced when the query runs.';

    /**
     * @description Loads the queryable objects in this org for the object picker.
     * @param {Object} result The wire result
     */
    @wire(getObjectOptions)
    wiredObjects({ data }) {
        if (data) {
            this.objectOptions = data.map((o) => ({ label: o.label, value: o.value }));
        }
    }

    /**
     * @description Loads the handler classes (and the functions each lists) for the Handler Class and Function dropdowns.
     * @param {Object} result The wire result
     */
    @wire(getHandlerOptions)
    wiredHandlers({ data }) {
        if (data) {
            this.handlerOptions = data;
        }
    }

    get handlerComboOptions() {
        const options = this.handlerOptions.map((h) => ({ label: h.className, value: h.className }));
        const current = this.form.handlerClass;
        if (current && !options.some((o) => o.value === current)) {
            options.push({ label: this.handlerOptions.length ? `${current} (not found in this org)` : current, value: current });
        }
        return options;
    }

    get handlerFunctions() {
        const handler = this.handlerOptions.find((h) => h.className === this.form.handlerClass);
        return handler ? handler.functions : [];
    }

    get hasFunctionList() {
        return this.handlerFunctions.length > 0 && !this.typingFunction;
    }

    get functionComboOptions() {
        const options = this.handlerFunctions.map((f) => ({ label: f, value: f }));
        const current = this.form.executionJob;
        if (current && !this.handlerFunctions.includes(current)) {
            options.push({ label: current, value: current });
        }
        options.push({ label: 'Other (type a name)', value: OTHER_FUNCTION });
        return options;
    }

    // The test choice only changes the query when a variable has a test value
    get hasTestParameters() {
        const variables = parseJobParameters(this.form.parameters).variables;
        return Array.isArray(variables) && variables.some((v) => v && v.testValue !== undefined && v.testValue !== '');
    }

    // Test Only jobs only ever run inside unit tests, so that is the version of the query worth checking by default
    get testAsUnitTest() {
        if (!this.hasTestParameters) return false;
        return this.testAsUnitTestChoice ?? this.form.frequency === 'Test Only';
    }

    handleTestAsUnitTestChange(event) {
        this.testAsUnitTestChoice = event.target.checked;
        this.queryResult = undefined;
        this.refreshPreview();
    }

    /**
     * @description Rebuilds the Built query panel shortly after a change (not on every keystroke).
     */
    refreshPreview() {
        clearTimeout(this.previewTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.previewTimer = setTimeout(() => this.loadPreview(), 300);
    }

    async loadPreview() {
        if (!this.form.fromObject) {
            this.builtQuery = undefined;
            return;
        }
        try {
            this.builtQuery = await buildQuery({ jobJson: JSON.stringify(this.form), asUnitTest: this.testAsUnitTest });
        } catch (error) {
            this.builtQuery = { errorMessage: reduceError(error) };
        }
    }

    get hasBuiltQuery() {
        return Boolean(this.builtQuery?.query || this.builtQuery?.errorMessage || this.builtQuery?.problems?.length || this.builtQuery?.warnings?.length);
    }

    get builtRunTitle() {
        const context = this.builtQuery?.asUnitTest ? 'when Test.isRunningTest() is true' : 'in a scheduled run (Test.isRunningTest() is false)';
        return this.builtQuery?.queryWithVariables ? `As it runs ${context}, variables filled in` : `As it runs ${context}`;
    }

    get queryRunLabel() {
        return this.queryResult?.asUnitTest ? 'Built as if Test.isRunningTest() is true' : 'Built as a scheduled run builds it (Test.isRunningTest() is false)';
    }

    get isFieldShift() {
        return this.form.jobType === 'Function' && (this.form.executionJob || '').toLowerCase() === 'fieldshift';
    }

    handleFunctionSelect(event) {
        if (event.detail.value === OTHER_FUNCTION) {
            this.typingFunction = true;
            return;
        }
        this.form = { ...this.form, executionJob: event.detail.value };
    }

    handleParametersChange(event) {
        // Only the builder's own event carries both values; ignore anything else that bubbles out of it
        if (event.detail?.parameters === undefined || event.detail?.whereClause === undefined) return;
        this.form = { ...this.form, parameters: event.detail.parameters, whereClause: event.detail.whereClause };
        this.queryResult = undefined;
        this.refreshPreview();
    }

    /**
     * @description Copies the form values into the plain query text boxes. LWC doesn't push a value binding into a
     * textarea, so this keeps them in sync; a box is only touched when it differs, so typing isn't disturbed.
     */
    renderedCallback() {
        this.template.querySelectorAll('[data-query-field]').forEach((box) => {
            const value = this.form[box.dataset.queryField] || '';
            if (box.value !== value) {
                box.value = value;
            }
        });
    }

    connectedCallback() {
        this.form = {
            active: false,
            isBatchJob: true,
            allOrNone: false,
            permDelete: false,
            jobType: 'DML',
            handlerClass: 'JobSequenceDefaultHandler',
            ...(this.job || {})
        };
        this.developerNameEdited = !this.isNew || Boolean(this.form.developerName);
        if (this.form.fromObject) {
            this.loadFields(this.form.fromObject);
            this.refreshPreview();
        }
    }

    /**
     * @description Loads an object's fields and related lists for the field chooser.
     * @param {String} objectName The object API name
     */
    async loadFields(objectName) {
        this.fieldsObject = objectName;
        try {
            const options = await getObjectFields({ objectName });
            if (this.fieldsObject !== objectName) return;
            this.fieldOptions = options.map((o) =>
                o.kind === 'child'
                    ? { label: o.label, value: o.value, kind: 'child', group: 'Related lists', detail: `(SELECT Id FROM ${o.value}) · ${o.childObject}` }
                    : {
                          label: o.label,
                          value: o.value,
                          kind: 'field',
                          group: 'Fields',
                          detail: `${o.value} · ${String(o.fieldType).toLowerCase()}`,
                          fieldType: o.fieldType,
                          updateable: o.updateable,
                          picklistValues: o.picklistValues
                      }
            );
        } catch (error) {
            this.fieldOptions = [];
        }
    }

    get fromLabel() {
        const match = this.objectOptions.find((o) => o.value === this.form.fromObject);
        return match ? match.label : this.form.fromObject;
    }

    get noObjectChosen() {
        return !this.form.fromObject;
    }

    get fromMissing() {
        return this.showQueryErrors && this.queryRequired && !this.form.fromObject;
    }

    get selectMissing() {
        return this.showQueryErrors && this.queryRequired && !(this.form.selectFields || '').trim();
    }

    get whereMissing() {
        return this.showQueryErrors && this.queryRequired && !(this.form.whereClause || '').trim();
    }

    get fieldPickerPlaceholder() {
        return this.form.fromObject ? 'Search fields' : 'Choose an object first';
    }

    get insertLabel() {
        return `Insert field into ${QUERY_FIELD_LABELS[this.insertTarget]}`;
    }

    get chooserHint() {
        return this.insertTarget === 'selectFields'
            ? 'Inserted at the cursor. Related lists are added as a subquery.'
            : 'Inserted at the cursor.';
    }

    get showSelectChooser() {
        return this.chooserOpen && this.insertTarget === 'selectFields';
    }

    get showWhereChooser() {
        return this.chooserOpen && this.insertTarget === 'whereClause';
    }

    get showOrderByChooser() {
        return this.chooserOpen && this.insertTarget === 'orderBy';
    }

    // The popup stays open while focus is in its query box or in the popup itself
    handleChooserFocusIn() {
        this.chooserHasFocus = true;
        clearTimeout(this.closeChooserTimer);
    }

    handleChooserFocusOut() {
        this.chooserHasFocus = false;
        this.scheduleChooserClose();
    }

    scheduleChooserClose() {
        clearTimeout(this.closeChooserTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.closeChooserTimer = setTimeout(() => {
            if (!this.chooserHasFocus && !this.queryBoxHasFocus) this.chooserOpen = false;
        }, 250);
    }

    get insertOptions() {
        // Related lists only make sense as subqueries in Select
        if (this.insertTarget === 'selectFields') return this.fieldOptions;
        const fields = this.fieldOptions.filter((o) => o.kind === 'field');
        return this.insertTarget === 'whereClause' ? [...this.variableOptions, ...fields] : fields;
    }

    /**
     * @description The variables defined in Job Parameters, then the built-in tokens, offered first in the Where
     * chooser so only a defined variable can be inserted.
     * @returns {Object[]} The variable and token options
     */
    get variableOptions() {
        const variables = parseJobParameters(this.form.parameters).variables;
        const defined = (Array.isArray(variables) ? variables : [])
            .filter((v) => v && /^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(v.name || ''))
            .map((v) => ({ label: `{!Var.${v.name}}`, value: `{!Var.${v.name}}`, kind: 'variable', group: 'Variables', detail: v.type }));
        return [...defined, ...BUILT_IN_TOKENS.map((t) => ({ ...t, kind: 'variable', group: 'Tokens' }))];
    }

    get insertExcludeValues() {
        return this.insertTarget === 'selectFields' ? this.selectedFieldNames : [];
    }

    get selectTextClass() {
        return this.queryTextClass('selectFields', this.selectMissing);
    }

    get whereTextClass() {
        return this.queryTextClass('whereClause', this.whereMissing);
    }

    get orderByTextClass() {
        return this.queryTextClass('orderBy', false);
    }

    /**
     * @description CSS classes for a query text box: SLDS input, highlighted when it is the insert target.
     * @param {String} field The form field
     * @param {Boolean} hasError Whether to show it as invalid
     * @returns {String} The class list
     */
    queryTextClass(field, hasError) {
        const base = field === 'orderBy' ? 'slds-input query-text' : 'slds-textarea query-text';
        return `${base}${this.insertTarget === field ? ' query-text_target' : ''}${hasError ? ' slds-has-error' : ''}`;
    }

    get selectedFieldNames() {
        return splitSelectList(this.form.selectFields);
    }


    handleObjectSelect(event) {
        const objectName = event.detail.value;
        const next = { ...this.form, fromObject: objectName };
        if (objectName !== this.form.fromObject) {
            // A new object starts with just Id; the old fields would not exist on it
            next.selectFields = 'Id';
            next.orderBy = null;
            this.cursorPositions = {};
        }
        this.form = next;
        this.queryResult = undefined;
        this.loadFields(objectName);
        this.refreshPreview();
    }

    get pasteToggleLabel() {
        return this.showPasteQuery ? 'Hide pasted query' : 'Paste a query';
    }

    handleTogglePaste() {
        this.showPasteQuery = !this.showPasteQuery;
        this.pasteError = undefined;
    }

    handlePastedQueryChange(event) {
        this.pastedQuery = event.detail.value;
        this.pasteError = undefined;
    }

    /**
     * @description Splits the pasted query into From, Select, Where, Order By and Record Limit and fills them in.
     */
    handleParseQuery() {
        const parsed = parseSoql(this.pastedQuery);
        if (parsed.error) {
            this.pasteError = parsed.error;
            return;
        }
        const object = this.objectOptions.find((o) => o.value.toLowerCase() === parsed.from.toLowerCase());
        if (this.objectOptions.length && !object) {
            this.pasteError = `There is no object named ${parsed.from} in this org.`;
            return;
        }
        const fromObject = object ? object.value : parsed.from;
        this.form = {
            ...this.form,
            fromObject,
            selectFields: parsed.select,
            whereClause: parsed.where,
            orderBy: parsed.orderBy,
            recordLimit: parsed.limit
        };
        this.cursorPositions = {};
        this.queryResult = undefined;
        this.pasteError = undefined;
        this.pasteNotes = ['Filled in From, Select, Where, Order By and Record Limit. Click Test Query to check it.', ...parsed.notes];
        this.showPasteQuery = false;
        this.loadFields(fromObject);
        this.refreshPreview();
    }

    handleQueryFocus(event) {
        this.insertTarget = event.target.dataset.queryField;
        this.queryBoxHasFocus = true;
        this.chooserOpen = true;
        clearTimeout(this.closeChooserTimer);
        this.handleQueryCursor(event);
    }

    handleQueryBlur(event) {
        this.handleQueryCursor(event);
        this.refreshPreview();
        this.queryBoxHasFocus = false;
        this.scheduleChooserClose();
    }

    handleQueryCursor(event) {
        this.cursorPositions[event.target.dataset.queryField] = event.target.selectionStart;
    }

    handleQueryKeyDown(event) {
        if (event.key === 'Escape' && this.chooserOpen) {
            // Close the popup without closing the modal
            event.stopPropagation();
            this.chooserOpen = false;
        }
    }

    handleQueryInput(event) {
        const field = event.target.dataset.queryField;
        this.form = { ...this.form, [field]: event.target.value };
        this.cursorPositions[field] = event.target.selectionStart;
        this.queryResult = undefined;
    }

    /**
     * @description Inserts the chosen field (or related-list subquery) at the cursor of the target text box, adding a
     * comma in Select and spaces elsewhere so it does not run into the surrounding text.
     * @param {CustomEvent} event The chooser's select event
     */
    handleInsertField(event) {
        const option = this.insertOptions.find((o) => o.value === event.detail.value);
        if (!option) return;
        const target = this.insertTarget;
        const text = option.kind === 'child' ? `(SELECT Id FROM ${option.value})` : option.value;
        const current = this.form[target] || '';
        const position = Math.min(this.cursorPositions[target] ?? current.length, current.length);
        const before = current.slice(0, position);
        const after = current.slice(position);

        let prefix = '';
        let suffix = '';
        if (target === 'selectFields' || target === 'orderBy') {
            // Select and Order By are comma-separated lists
            const lastChar = before.trimEnd().slice(-1);
            const nextChar = after.trimStart().charAt(0);
            if (before.trim() && lastChar !== ',' && lastChar !== '(') prefix = ', ';
            else if (before && !/\s$/.test(before)) prefix = ' ';
            if (after.trim() && nextChar !== ',' && nextChar !== ')') suffix = ', ';
        } else {
            if (before && !/\s$/.test(before)) prefix = ' ';
            if (after && !/^\s/.test(after)) suffix = ' ';
        }

        const inserted = `${before}${prefix}${text}${suffix}`;
        this.form = { ...this.form, [target]: `${inserted}${after}` };
        this.cursorPositions[target] = inserted.length;
        this.queryResult = undefined;

        // Put the cursor back after the inserted text once the box has re-rendered
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const box = this.template.querySelector(`[data-query-field="${target}"]`);
            if (box) {
                box.focus();
                box.setSelectionRange(inserted.length, inserted.length);
            }
        }, 0);
    }

    get title() {
        if (!this.isNew) return `Edit ${this.form.label || 'Sequence Job'}`;
        return this.job ? 'Clone Sequence Job' : 'New Sequence Job';
    }

    get isDeveloperNameLocked() {
        return !this.isNew || this.isSaving;
    }

    get isDml() {
        return this.form.jobType === 'DML';
    }

    get isDelete() {
        return this.isDml && (this.form.executionJob || '').toUpperCase() === 'DELETE';
    }

    get allOrNoneHelp() {
        return this.isDml
            ? 'Checked: if one record in a batch fails, the whole batch fails. Unchecked: the other records still save, and the failures are counted on the run.'
            : 'Used when the function saves records, e.g. FieldShift: checked, one failed record fails the whole batch; unchecked, the others still save.';
    }

    get isBusy() {
        return this.isSaving || this.isTesting;
    }

    get frequencyComboOptions() {
        return this.frequencyOptions.map((value) => ({ label: value, value }));
    }

    get jobTypeComboOptions() {
        return this.jobTypeOptions.map((value) => ({ label: value, value }));
    }

    get queryRequired() {
        return this.form.isBatchJob === true;
    }

    get hasQueryResult() {
        return Boolean(this.queryResult);
    }

    get queryResultSummary() {
        const r = this.queryResult;
        if (!r) return '';
        if (!r.isValid) return r.errorMessage;
        const rows = r.moreThanLimit ? `More than ${r.countLimit.toLocaleString()}` : r.matchingRows.toLocaleString();
        return `The query is valid. Matching rows right now: ${rows}.`;
    }

    get queryResultClass() {
        return this.queryResult?.isValid ? 'slds-text-color_success' : 'slds-text-color_error';
    }

    handleChange(event) {
        const field = event.target.dataset.field;
        let value;
        if (CHECKBOX_FIELDS.includes(field)) {
            value = event.target.checked;
        } else if (NUMBER_FIELDS.includes(field)) {
            value = event.target.value === '' || event.target.value === null ? null : Number(event.target.value);
        } else {
            value = event.detail?.value ?? event.target.value;
        }
        const next = { ...this.form, [field]: value };

        if (field === 'label' && this.isNew && !this.developerNameEdited) {
            next.developerName = toDeveloperName(value);
        }
        if (field === 'developerName') {
            this.developerNameEdited = true;
        }
        if (field === 'jobType' && value === 'DML' && !DML_OPTIONS.some((o) => o.value === (next.executionJob || '').toUpperCase())) {
            next.executionJob = 'UPDATE';
        }
        if (field === 'jobType' && value === 'Function' && DML_OPTIONS.some((o) => o.value === (next.executionJob || '').toUpperCase())) {
            // Start a new function job on the handler's first listed function, e.g. FieldShift
            next.executionJob = this.handlerFunctions[0] || '';
            this.typingFunction = false;
        }
        if (field === 'handlerClass') {
            this.typingFunction = false;
        }
        // Permanent Delete only applies to DELETE jobs; clear it when the job no longer deletes
        if ((field === 'executionJob' || field === 'jobType') && !(next.jobType === 'DML' && (next.executionJob || '').toUpperCase() === 'DELETE')) {
            next.permDelete = false;
        }
        this.form = next;
        if (['selectFields', 'fromObject', 'whereClause', 'orderBy', 'recordLimit', 'parameters', 'frequency'].includes(field)) {
            this.queryResult = undefined;
            this.refreshPreview();
        }
    }

    /**
     * @description Checks every input's own validity (required, ranges, lengths) and shows the messages.
     * @returns {Boolean} True when all inputs are valid
     */
    validateInputs() {
        const inputs = [...this.template.querySelectorAll('lightning-input, lightning-combobox, lightning-textarea')];
        const inputsValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        // The object picker and the query text boxes are not base components, so check them here
        this.showQueryErrors = true;
        return inputsValid && !this.fromMissing && !this.selectMissing && !this.whereMissing;
    }

    async handleTestQuery() {
        this.isTesting = true;
        this.errorLines = undefined;
        try {
            this.queryResult = await testQuery({ jobJson: JSON.stringify(this.form), asUnitTest: this.testAsUnitTest });
            this.loadPreview();
        } catch (error) {
            this.queryResult = { isValid: false, errorMessage: reduceError(error) };
        } finally {
            this.isTesting = false;
        }
    }

    /**
     * @description Submits the save, then waits for the deployment result before closing.
     */
    async handleSave() {
        this.errorLines = undefined;
        if (!this.validateInputs()) {
            return;
        }
        this.isSaving = true;
        this.disableClose = true;
        try {
            await ensureSubscribed();
            const deploymentId = await saveSequenceJob({ jobJson: JSON.stringify(this.form), isNew: this.isNew });
            const result = await waitForDeployment(deploymentId);
            if (result.status === 'Succeeded') {
                this.disableClose = false;
                this.close({ status: 'saved', label: this.form.label });
                return;
            }
            if (result.status === 'Timeout') {
                this.disableClose = false;
                this.close({ status: 'pending', label: this.form.label });
                return;
            }
            this.errorLines = (result.message || `The save ${String(result.status).toLowerCase()}.`).split('\n');
        } catch (error) {
            this.errorLines = reduceError(error).split('\n');
        } finally {
            this.isSaving = false;
            this.disableClose = false;
        }
    }

    handleCancel() {
        this.close({ status: 'cancelled' });
    }
}
