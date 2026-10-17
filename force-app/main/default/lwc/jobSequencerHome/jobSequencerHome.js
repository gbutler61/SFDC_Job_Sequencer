/**
 * @description jobSequencerHome -- Home page dashboard for the Job Sequencer app: status tiles, errors and records per
 * day, frequency performance, slowest jobs, recent runs, recent errors and the jobs that fail most.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getHomeData from '@salesforce/apex/JobSequencerHomeController.getHomeData';

const PROBLEM_STATUSES = ['Failed', 'Abandoned'];
const NOTICE_STATUSES = ['Disabled'];

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
 * @description Formats a number of seconds as seconds, minutes or hours.
 * @param {Number} seconds The duration
 * @returns {String} The readable duration, or a dash when unknown
 */
function formatDuration(seconds) {
    if (seconds === null || seconds === undefined) return '—';
    if (seconds < 60) return `${Math.round(seconds)} sec`;
    if (seconds < 3600) return `${Math.round(seconds / 6) / 10} min`;
    return `${Math.round(seconds / 360) / 10} hr`;
}

export default class JobSequencerHome extends NavigationMixin(LightningElement) {
    data;
    loadError;
    isLoading = true;

    numberFormatter = new Intl.NumberFormat();

    connectedCallback() {
        this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            this.data = await getHomeData();
            this.loadError = undefined;
        } catch (error) {
            this.loadError = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleRefresh() {
        this.loadData();
    }

    // ---------- Tiles ----------

    get hasData() {
        return Boolean(this.data);
    }

    get sequencerLabel() {
        return this.data.sequencerEnabled ? 'On' : 'Off';
    }

    get sequencerIcon() {
        return this.data.sequencerEnabled ? 'utility:success' : 'utility:warning';
    }

    get sequencerIconVariant() {
        return this.data.sequencerEnabled ? 'success' : 'warning';
    }

    get sequencerDetail() {
        return this.data.sequencerEnabled ? 'Sequence jobs run when scheduled' : 'No sequence jobs will run';
    }

    get scheduledLabel() {
        return `${this.data.scheduledCount} of ${this.data.frequencyCount}`;
    }

    get hasNextRun() {
        return Boolean(this.data.nextRunTime);
    }

    get errorTrendDetail() {
        const diff = this.data.errorsLast7Days - this.data.errorsPrior7Days;
        if (diff === 0) {
            return 'Same as the previous 7 days';
        }
        const arrow = diff > 0 ? '▲' : '▼';
        return `${arrow} ${Math.abs(diff)} ${diff > 0 ? 'more' : 'fewer'} than the previous 7 days`;
    }

    // ---------- Tables ----------

    get frequencyStats() {
        return (this.data?.frequencyStats || []).map((fs) => ({
            ...fs,
            averageLabel: formatDuration(fs.averageSeconds),
            maxLabel: formatDuration(fs.maxSeconds),
            recordsLabel: this.numberFormatter.format(fs.recordsProcessed),
            failedLabel: this.numberFormatter.format(fs.recordsFailed),
            skippedClass: fs.timesSkipped > 0 ? 'slds-text-color_error' : ''
        }));
    }

    get hasFrequencyStats() {
        return this.frequencyStats.length > 0;
    }

    get slowestJobs() {
        return (this.data?.slowestJobs || []).map((job) => ({
            ...job,
            averageLabel: formatDuration(job.averageSeconds),
            recordsLabel: this.numberFormatter.format(job.recordsProcessed)
        }));
    }

    get hasSlowestJobs() {
        return this.slowestJobs.length > 0;
    }

    get recentRuns() {
        return (this.data?.recentRuns || []).map((run) => {
            let statusClass = '';
            if (run.status === 'Completed') statusClass = 'slds-theme_success';
            if (PROBLEM_STATUSES.includes(run.status)) statusClass = 'slds-theme_error';
            if (NOTICE_STATUSES.includes(run.status)) statusClass = 'slds-theme_warning';
            return {
                ...run,
                statusClass,
                durationLabel: run.status === 'Running' ? 'In progress' : formatDuration(run.durationSeconds),
                recordsLabel: this.numberFormatter.format(run.recordsProcessed),
                detail: run.detail || ''
            };
        });
    }

    get hasRecentRuns() {
        return this.recentRuns.length > 0;
    }

    get hasRecentErrors() {
        return (this.data?.recentErrors || []).length > 0;
    }

    get hasTopFailingJobs() {
        return (this.data?.topFailingJobs || []).length > 0;
    }

    // ---------- Navigation ----------

    handleOpenTab(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: event.currentTarget.dataset.tab }
        });
    }

    handleOpenRecord(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' }
        });
    }

    handleOpenErrors() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Job_Sequence_Error__c', actionName: 'list' },
            state: { filterName: 'All' }
        });
    }

    handleOpenRuns() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Job_Sequence_Run__c', actionName: 'list' },
            state: { filterName: 'All' }
        });
    }
}
