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
 * @description jobSequenceManager -- The Sequence Jobs tab: lists Sequence Job records by frequency and run order,
 * with filters and search, and creates, clones, edits, activates, deactivates and reorders them without going into
 * Setup; selected jobs can be activated, deactivated or moved to another frequency together.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import JobSequenceEditor from 'c/jobSequenceEditor';
import { ensureSubscribed, waitForDeployment } from 'c/jobSequenceDeployWatcher';
import getSequenceJobs from '@salesforce/apex/JobSequenceManagerController.getSequenceJobs';
import getFieldOptions from '@salesforce/apex/JobSequenceManagerController.getFieldOptions';
import setActive from '@salesforce/apex/JobSequenceManagerController.setActive';
import moveJob from '@salesforce/apex/JobSequenceManagerController.moveJob';
import runStandalone from '@salesforce/apex/JobSequenceManagerController.runStandalone';
import setActiveForJobs from '@salesforce/apex/JobSequenceManagerController.setActiveForJobs';
import changeFrequency from '@salesforce/apex/JobSequenceManagerController.changeFrequency';

// The "any value" choice in every filter
const ALL = '__all__';
// Only One Time jobs can be run on their own
const STANDALONE_FREQUENCY = 'One Time';

const DEFAULT_FILTERS = { frequency: ALL, status: ALL, fromObject: ALL, jobType: ALL, handlerClass: ALL, executionJob: ALL };
const STATUS_OPTIONS = [
    { label: 'All', value: ALL },
    { label: 'Active', value: 'active' },
    { label: 'Inactive', value: 'inactive' }
];
// The job values the search box looks in
const SEARCH_FIELDS = ['label', 'developerName', 'description', 'fromObject', 'handlerClass', 'executionJob', 'order'];

const COLUMNS = [
    { label: 'Frequency', fieldName: 'frequency', initialWidth: 140 },
    { label: 'Order', fieldName: 'order', initialWidth: 80 },
    { label: 'Label', fieldName: 'label', wrapText: true },
    { label: 'Description', fieldName: 'description', wrapText: true, wrapTextMaxLines: 3, initialWidth: 280 },
    { label: 'Active', fieldName: 'active', type: 'boolean', initialWidth: 75 },
    { label: 'Object', fieldName: 'fromObject', initialWidth: 140 },
    { label: 'Type', fieldName: 'jobType', initialWidth: 95 },
    { label: 'Runs as', fieldName: 'modeLabel', initialWidth: 105 },
    { label: 'Execution', fieldName: 'executionJob', initialWidth: 120 },
    { label: 'Handler', fieldName: 'handlerClass', wrapText: true },
    {
        type: 'button-icon',
        initialWidth: 50,
        typeAttributes: { name: 'edit', iconName: 'utility:edit', alternativeText: 'Edit', title: 'Edit' }
    },
    { type: 'action', typeAttributes: { rowActions: (row, done) => done(row.rowActions) } }
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
 * @description Builds filter options from the distinct values the jobs use, sorted, after an "All" choice.
 * @param {Object[]} jobs The jobs
 * @param {String} field The job property to collect
 * @returns {Object[]} The combobox options
 */
function distinctOptions(jobs, field) {
    const values = [...new Set(jobs.map((j) => j[field]).filter((v) => v))].sort((a, b) => a.localeCompare(b));
    return [{ label: 'All', value: ALL }, ...values.map((v) => ({ label: v, value: v }))];
}

/**
 * @description Joins job labels for a toast, naming at most a few.
 * @param {String[]} labels The job labels
 * @returns {String} The labels, e.g. "A, B, C and 2 more"
 */
function nameList(labels) {
    const shown = labels.slice(0, 3).join(', ');
    return labels.length > 3 ? `${shown} and ${labels.length - 3} more` : shown;
}

export default class JobSequenceManager extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    jobs = [];
    frequencyOptions = [];
    jobTypeOptions = [];
    filters = { ...DEFAULT_FILTERS };
    searchTerm = '';
    statusFilterOptions = STATUS_OPTIONS;
    selectedKeys = [];
    // Reset after each choice, so the same frequency can be picked again
    moveToFrequency = null;
    loadError;
    isLoading = true;
    pendingSaves = 0;

    connectedCallback() {
        ensureSubscribed();
        this.loadOptions();
        this.loadJobs();
    }

    async loadOptions() {
        try {
            const options = await getFieldOptions();
            this.frequencyOptions = options.frequencies;
            this.jobTypeOptions = options.jobTypes;
        } catch (error) {
            this.loadError = reduceError(error);
        }
    }

    async loadJobs() {
        this.isLoading = true;
        try {
            this.jobs = await getSequenceJobs();
            this.loadError = undefined;
        } catch (error) {
            this.loadError = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    get frequencyFilterOptions() {
        return [{ label: 'All', value: ALL }, ...this.frequencyOptions.map((f) => ({ label: f, value: f }))];
    }

    get typeFilterOptions() {
        return [{ label: 'All', value: ALL }, ...this.jobTypeOptions.map((t) => ({ label: t, value: t }))];
    }

    get objectFilterOptions() {
        return distinctOptions(this.jobs, 'fromObject');
    }

    get handlerFilterOptions() {
        return distinctOptions(this.jobs, 'handlerClass');
    }

    get executionFilterOptions() {
        return distinctOptions(this.jobs, 'executionJob');
    }

    get moveFrequencyOptions() {
        return this.frequencyOptions.map((f) => ({ label: f, value: f }));
    }

    /**
     * @description Checks a job against the filters and the search box.
     * @param {Object} job The job
     * @returns {Boolean} True when the job should be listed
     */
    matchesFilters(job) {
        const f = this.filters;
        if (f.frequency !== ALL && job.frequency !== f.frequency) return false;
        if (f.status !== ALL && job.active !== (f.status === 'active')) return false;
        if (f.fromObject !== ALL && job.fromObject !== f.fromObject) return false;
        if (f.jobType !== ALL && job.jobType !== f.jobType) return false;
        if (f.handlerClass !== ALL && job.handlerClass !== f.handlerClass) return false;
        if (f.executionJob !== ALL && job.executionJob !== f.executionJob) return false;
        const term = this.searchTerm.trim().toLowerCase();
        return !term || SEARCH_FIELDS.some((field) => (job[field] || '').toLowerCase().includes(term));
    }

    get visibleJobs() {
        return this.jobs.filter((job) => this.matchesFilters(job));
    }

    get isFiltered() {
        return this.searchTerm.trim() !== '' || Object.keys(DEFAULT_FILTERS).some((key) => this.filters[key] !== DEFAULT_FILTERS[key]);
    }

    get countText() {
        const shown = this.visibleJobs.length;
        const total = this.jobs.length;
        return shown === total ? `${total} job${total === 1 ? '' : 's'}` : `${shown} of ${total} jobs`;
    }

    get hasJobs() {
        return this.jobs.length > 0;
    }

    /**
     * @description The selected jobs that are still listed; a filter change can hide selected rows.
     * @returns {Object[]} The selected jobs
     */
    get selectedJobs() {
        const keys = new Set(this.selectedKeys);
        return this.visibleJobs.filter((job) => keys.has(job.developerName));
    }

    get hasSelection() {
        return this.selectedJobs.length > 0;
    }

    get selectionText() {
        const count = this.selectedJobs.length;
        return `${count} selected`;
    }

    /**
     * @description The rows that pass the filters, with each row's available actions.
     * @returns {Object[]} The table rows
     */
    get rows() {
        return this.visibleJobs.map((job) => {
            const siblings = this.jobs.filter((j) => j.frequency === job.frequency);
            const position = siblings.findIndex((j) => j.developerName === job.developerName);
            const rowActions = [
                { label: 'Clone', name: 'clone', iconName: 'utility:copy' },
                job.active
                    ? { label: 'Deactivate', name: 'deactivate', iconName: 'utility:block_visitor' }
                    : { label: 'Activate', name: 'activate', iconName: 'utility:check' },
                { label: 'Move up', name: 'up', iconName: 'utility:arrowup', disabled: position <= 0 },
                { label: 'Move down', name: 'down', iconName: 'utility:arrowdown', disabled: position >= siblings.length - 1 },
                { label: 'Open in Setup', name: 'setup', iconName: 'utility:new_window' }
            ];
            if (job.frequency === STANDALONE_FREQUENCY) {
                rowActions.unshift({
                    label: job.active ? 'Run standalone' : 'Run standalone (activate it first)',
                    name: 'standalone',
                    iconName: 'utility:play',
                    disabled: !job.active
                });
            }
            return { ...job, modeLabel: job.isBatchJob ? 'Batch' : 'Queueable', rowActions };
        });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isSaving() {
        return this.pendingSaves > 0;
    }

    get pendingMessage() {
        return `Saving ${this.pendingSaves} change${this.pendingSaves === 1 ? '' : 's'}… Custom metadata saves run in the background.`;
    }

    handleFilterChange(event) {
        this.filters = { ...this.filters, [event.target.dataset.filter]: event.detail.value };
        this.pruneSelection();
    }

    handleSearchChange(event) {
        this.searchTerm = event.detail.value || '';
        this.pruneSelection();
    }

    handleClearFilters(event) {
        event.preventDefault();
        this.filters = { ...DEFAULT_FILTERS };
        this.searchTerm = '';
    }

    /**
     * @description Drops selected rows the filters now hide, so an action only touches jobs that are listed.
     */
    pruneSelection() {
        this.selectedKeys = this.selectedJobs.map((job) => job.developerName);
    }

    handleRowSelection(event) {
        this.selectedKeys = event.detail.selectedRows.map((row) => row.developerName);
    }

    handleClearSelection() {
        this.selectedKeys = [];
    }

    handleMassActivate() {
        this.massSetActive(true);
    }

    handleMassDeactivate() {
        this.massSetActive(false);
    }

    /**
     * @description Activates or deactivates the selected jobs in one save, confirming a deactivation first.
     * @param {Boolean} active True to activate, false to deactivate
     */
    async massSetActive(active) {
        const jobs = this.selectedJobs;
        if (!active) {
            const confirmed = await LightningConfirm.open({
                label: `Deactivate ${jobs.length} job${jobs.length === 1 ? '' : 's'}?`,
                message: 'They will be skipped when their frequency runs. To delete one permanently, use Open in Setup.',
                theme: 'warning'
            });
            if (!confirmed) return;
        }
        this.runMassUpdate(
            () => setActiveForJobs({ developerNames: jobs.map((j) => j.developerName), active }),
            active ? 'activated' : 'deactivated',
            active ? 'already active' : 'already inactive'
        );
    }

    /**
     * @description Moves the selected jobs to the chosen frequency in one save, after confirming. Each job keeps its
     * Order and sorts into the new frequency by it.
     * @param {Event} event The combobox change
     */
    async handleMassFrequency(event) {
        const frequency = event.detail.value;
        // Show the choice while the confirm is open, then clear it so the same value can be chosen again
        this.moveToFrequency = frequency;
        const jobs = this.selectedJobs;
        const confirmed = await LightningConfirm.open({
            label: `Move ${jobs.length} job${jobs.length === 1 ? '' : 's'} to ${frequency}?`,
            message: `They keep their Order values and run in that order within ${frequency}. Use Move up/down or Edit afterwards to place them.`,
            theme: 'warning'
        });
        this.moveToFrequency = null;
        if (!confirmed) return;
        this.runMassUpdate(
            () => changeFrequency({ developerNames: jobs.map((j) => j.developerName), frequency }),
            `moved to ${frequency}`,
            `already ${frequency}`
        );
    }

    /**
     * @description Starts a mass update, waits for its deployment, and reports which jobs changed, which already had
     * the value and which were left out because they need a description. Clears the selection afterwards.
     * @param {Function} action A function returning the Apex call that starts the update
     * @param {String} doneText How the changed jobs are described, e.g. "activated"
     * @param {String} unchangedText How the untouched jobs are described, e.g. "already active"
     */
    async runMassUpdate(action, doneText, unchangedText) {
        this.pendingSaves++;
        try {
            await ensureSubscribed();
            const result = await action();
            const notes = [];
            if (result.unchanged.length) notes.push(`${nameList(result.unchanged)} ${result.unchanged.length === 1 ? 'was' : 'were'} ${unchangedText}.`);
            if (result.needDescription.length) {
                notes.push(`Left out, because they need a description of 25+ characters first (Edit to add one): ${nameList(result.needDescription)}.`);
            }
            if (!result.deploymentId) {
                this.toast(result.needDescription.length ? 'warning' : 'info', 'Nothing to save', notes.join(' '));
                return;
            }
            const outcome = await waitForDeployment(result.deploymentId);
            const count = result.updated.length;
            if (outcome.status === 'Succeeded') {
                const message = [`${count} job${count === 1 ? '' : 's'} ${doneText}.`, ...notes].join(' ');
                this.toast(result.needDescription.length ? 'warning' : 'success', 'Saved', message);
            } else if (outcome.status === 'Timeout') {
                this.toast('info', 'Still saving', 'The change is still saving. Refresh the list in a minute to see it.');
            } else {
                this.toast('error', 'Not saved', outcome.message || `The save ${String(outcome.status).toLowerCase()}.`);
            }
        } catch (error) {
            this.toast('error', 'Not saved', reduceError(error));
        } finally {
            this.pendingSaves--;
            this.selectedKeys = [];
            this.loadJobs();
        }
    }

    handleRefresh() {
        this.loadJobs();
    }

    handleNew() {
        const frequency = this.filters.frequency === ALL ? undefined : this.filters.frequency;
        this.openEditor(frequency ? { frequency } : undefined, true);
    }

    handleRowAction(event) {
        const { action, row } = event.detail;
        switch (action.name) {
            case 'edit':
                this.openEditor(this.stripRow(row), false);
                break;
            case 'clone':
                this.openEditor(
                    {
                        ...this.stripRow(row),
                        recordId: undefined,
                        developerName: `${row.developerName}_COPY`.substring(0, 40),
                        label: `Copy of ${row.label}`.substring(0, 40),
                        active: false
                    },
                    true
                );
                break;
            case 'activate':
            case 'deactivate':
                this.changeActive(row, action.name === 'activate');
                break;
            case 'up':
            case 'down':
                this.runDeploy(() => moveJob({ developerName: row.developerName, direction: action.name }), `${row.label} moved ${action.name}.`);
                break;
            case 'standalone':
                this.runStandaloneJob(row);
                break;
            case 'setup':
                this[NavigationMixin.Navigate]({
                    type: 'standard__webPage',
                    attributes: { url: `/lightning/setup/CustomMetadata/page?address=%2F${row.recordId}` }
                });
                break;
            default:
        }
    }

    /**
     * @description Removes the display-only properties from a row before it goes to the editor.
     * @param {Object} row The table row
     * @returns {Object} The job values
     */
    stripRow(row) {
        // eslint-disable-next-line no-unused-vars
        const { modeLabel, rowActions, ...job } = row;
        return job;
    }

    async openEditor(job, isNew) {
        const result = await JobSequenceEditor.open({
            size: 'large',
            label: isNew ? 'New Sequence Job' : 'Edit Sequence Job',
            job,
            isNew,
            frequencyOptions: this.frequencyOptions,
            jobTypeOptions: this.jobTypeOptions
        });
        if (result?.status === 'saved') {
            this.toast('success', 'Saved', `${result.label} was saved.`);
            this.loadJobs();
        } else if (result?.status === 'pending') {
            this.toast('info', 'Still saving', `${result.label} is still saving. Refresh the list in a minute to see it.`);
        }
    }

    async changeActive(row, active) {
        if (!active) {
            const confirmed = await LightningConfirm.open({
                label: `Deactivate ${row.label}?`,
                message: 'It will be skipped when its frequency runs. To delete it permanently, use Open in Setup.',
                theme: 'warning'
            });
            if (!confirmed) return;
        }
        this.runDeploy(
            () => setActive({ developerName: row.developerName, active }),
            `${row.label} was ${active ? 'activated' : 'deactivated'}.`
        );
    }

    /**
     * @description Starts a save, waits for its deployment result, then reports it and refreshes the list.
     * @param {Function} action A function returning the Apex call that starts the deployment
     * @param {String} successMessage The message to show when it succeeds
     */
    async runDeploy(action, successMessage) {
        this.pendingSaves++;
        try {
            await ensureSubscribed();
            const deploymentId = await action();
            const result = await waitForDeployment(deploymentId);
            if (result.status === 'Succeeded') {
                this.toast('success', 'Saved', successMessage);
            } else if (result.status === 'Timeout') {
                this.toast('info', 'Still saving', 'The change is still saving. Refresh the list in a minute to see it.');
            } else {
                this.toast('error', 'Not saved', result.message || `The save ${String(result.status).toLowerCase()}.`);
            }
        } catch (error) {
            this.toast('error', 'Not saved', reduceError(error));
        } finally {
            this.pendingSaves--;
            this.loadJobs();
        }
    }

    /**
     * @description Runs one One Time job on its own, after confirming: no other One Time job runs. The run shows
     * on the home page and in Run History.
     * @param {Object} row The job's row
     */
    async runStandaloneJob(row) {
        const confirmed = await LightningConfirm.open({
            label: `Run ${row.label} on its own?`,
            message: `Only ${row.label} runs, now, and it changes records exactly as a scheduled run would. Other One Time jobs don't run.`,
            theme: 'warning'
        });
        if (!confirmed) return;
        try {
            await runStandalone({ developerName: row.developerName });
            this.toast('success', 'Started', `${row.label} is running on its own. Follow it on the Job Sequencer home page.`);
        } catch (error) {
            this.toast('error', 'Not started', reduceError(error));
        }
    }

    toast(variant, title, message) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode: variant === 'error' ? 'sticky' : 'dismissible' }));
    }
}
