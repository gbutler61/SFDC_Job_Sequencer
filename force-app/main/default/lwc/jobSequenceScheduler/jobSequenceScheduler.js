/**
 * @description jobSequenceScheduler -- Dashboard for the out of the box frequencies (Hourly through Yearly): shows
 * whether each is scheduled, its next and last run, active sequence jobs and recent errors, and lets an admin
 * schedule, unschedule or run a frequency now.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getDashboardData from '@salesforce/apex/JobSequenceSchedulerController.getDashboardData';
import scheduleRun from '@salesforce/apex/JobSequenceSchedulerController.scheduleRun';
import scheduleAllRuns from '@salesforce/apex/JobSequenceSchedulerController.scheduleAllRuns';
import unscheduleRun from '@salesforce/apex/JobSequenceSchedulerController.unscheduleRun';
import runNow from '@salesforce/apex/JobSequenceSchedulerController.runNow';

// CronTrigger states that mean the schedule is healthy
const HEALTHY_STATES = ['WAITING', 'ACQUIRED', 'EXECUTING'];

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

export default class JobSequenceScheduler extends NavigationMixin(LightningElement) {
    data;
    loadError;
    isBusy = true;

    connectedCallback() {
        this.loadData();
    }

    get hasRows() {
        return Boolean(this.data?.frequencies?.length);
    }

    get errorLookbackDays() {
        return this.data?.errorLookbackDays;
    }

    get showDisabledWarning() {
        return this.data && !this.data.sequencerEnabled;
    }

    get isScheduleAllDisabled() {
        return this.isBusy || !this.hasRows || this.data.frequencies.every((f) => f.isScheduled);
    }

    /**
     * @description Adds display values (badge label and style, Run Now availability) to each frequency.
     * @returns {Object[]} The table rows
     */
    get rows() {
        return (this.data?.frequencies || []).map((f) => {
            const healthy = f.isScheduled && HEALTHY_STATES.includes(f.state);
            let statusLabel = 'Not scheduled';
            if (f.isScheduled) {
                statusLabel = healthy ? 'Scheduled' : `Scheduled (${f.state})`;
            }
            let statusClass = '';
            if (f.isScheduled) {
                statusClass = healthy ? 'slds-theme_success' : 'slds-theme_warning';
            }
            return {
                ...f,
                statusLabel,
                statusClass,
                isRunNowDisabled: this.isBusy || !this.data.sequencerEnabled || !f.activeJobCount
            };
        });
    }

    /**
     * @description Loads the dashboard data from Apex.
     */
    async loadData() {
        this.isBusy = true;
        try {
            this.data = await getDashboardData();
            this.loadError = undefined;
        } catch (error) {
            this.loadError = reduceError(error);
        } finally {
            this.isBusy = false;
        }
    }

    /**
     * @description Runs an Apex action, shows a toast for the outcome, then reloads the dashboard.
     * @param {Function} action A function returning the Apex call's promise
     * @param {Function} successMessage Builds the success message from the Apex result
     */
    async runAction(action, successMessage) {
        this.isBusy = true;
        try {
            const result = await action();
            this.toast('success', successMessage(result));
        } catch (error) {
            this.toast('error', reduceError(error));
        }
        await this.loadData();
    }

    toast(variant, message) {
        const title = variant === 'success' ? 'Done' : 'Action failed';
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode: variant === 'error' ? 'sticky' : 'dismissible' }));
    }

    handleRefresh() {
        this.loadData();
    }

    handleSchedule(event) {
        const frequency = event.target.dataset.frequency;
        this.runAction(() => scheduleRun({ frequency }), () => `The ${frequency} run is scheduled.`);
    }

    handleScheduleAll() {
        this.runAction(
            () => scheduleAllRuns(),
            (count) => `${count} run${count === 1 ? '' : 's'} scheduled.`
        );
    }

    async handleUnschedule(event) {
        const frequency = event.target.dataset.frequency;
        const confirmed = await LightningConfirm.open({
            label: `Unschedule the ${frequency} run?`,
            message: `${frequency} sequence jobs will stop running on a schedule until it is scheduled again. A run that has already started is not interrupted.`,
            theme: 'warning'
        });
        if (confirmed) {
            this.runAction(() => unscheduleRun({ frequency }), () => `The ${frequency} run is unscheduled.`);
        }
    }

    async handleRunNow(event) {
        const frequency = event.target.dataset.frequency;
        const confirmed = await LightningConfirm.open({
            label: `Run the ${frequency} sequence now?`,
            message: `All active ${frequency} sequence jobs run now, in order, and change records exactly as a scheduled run would.`,
            theme: 'warning'
        });
        if (confirmed) {
            this.runAction(() => runNow({ frequency }), () => `The ${frequency} sequence has started.`);
        }
    }

    handleOpenErrors() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'Job_Sequence_Error__c', actionName: 'list' },
            state: { filterName: 'All' }
        });
    }

    handleOpenSettings() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Job_Sequencer_Settings' }
        });
    }
}
