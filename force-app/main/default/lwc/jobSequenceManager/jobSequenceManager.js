/**
 * @description jobSequenceManager -- The Sequence Jobs tab: lists Sequence Job records by frequency and run order,
 * and creates, clones, edits, activates, deactivates and reorders them without going into Setup.
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

const ALL_FREQUENCIES = '__all__';

const COLUMNS = [
    { label: 'Frequency', fieldName: 'frequency', initialWidth: 150 },
    { label: 'Order', fieldName: 'order', initialWidth: 90 },
    { label: 'Label', fieldName: 'label', wrapText: true },
    { label: 'Active', fieldName: 'active', type: 'boolean', initialWidth: 80 },
    { label: 'Type', fieldName: 'jobType', initialWidth: 100 },
    { label: 'Runs as', fieldName: 'modeLabel', initialWidth: 110 },
    { label: 'Execution', fieldName: 'executionJob', initialWidth: 130 },
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

export default class JobSequenceManager extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    jobs = [];
    frequencyOptions = [];
    jobTypeOptions = [];
    selectedFrequency = ALL_FREQUENCIES;
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

    get filterOptions() {
        return [{ label: 'All frequencies', value: ALL_FREQUENCIES }, ...this.frequencyOptions.map((f) => ({ label: f, value: f }))];
    }

    /**
     * @description The rows for the selected frequency, with each row's available actions.
     * @returns {Object[]} The table rows
     */
    get rows() {
        const visible = this.jobs.filter((j) => this.selectedFrequency === ALL_FREQUENCIES || j.frequency === this.selectedFrequency);
        return visible.map((job) => {
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
        this.selectedFrequency = event.detail.value;
    }

    handleRefresh() {
        this.loadJobs();
    }

    handleNew() {
        const frequency = this.selectedFrequency === ALL_FREQUENCIES ? undefined : this.selectedFrequency;
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

    toast(variant, title, message) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode: variant === 'error' ? 'sticky' : 'dismissible' }));
    }
}
