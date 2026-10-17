/**
 * @description jobSequenceSettings -- Edits the org-wide defaults of the Sequence Jobs Settings custom setting
 * (Enabled, Max Retries, Minutes Until Retry). Replaces the redirect to the Classic custom settings page.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSettings from '@salesforce/apex/JobSequenceSettingsController.getSettings';
import saveSettings from '@salesforce/apex/JobSequenceSettingsController.saveSettings';

// Field limits: MaxRetries__c is Number(3, 0) and MinutesUntilRetry__c is Number(2, 0)
const MAX_RETRIES_LIMIT = 999;
const MINUTES_UNTIL_RETRY_LIMIT = 99;

/**
 * @description Pulls a readable message out of an Apex or LDS error.
 * @param {Object} error The error returned by the wire service or an imperative Apex call
 * @returns {String} The message to show the user
 */
function reduceError(error) {
    if (Array.isArray(error?.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error?.body?.message || error?.message || 'Unknown error';
}

export default class JobSequenceSettings extends LightningElement {
    enabled = true;
    maxRetries;
    minutesUntilRetry;
    savedValues;
    loadError;
    isSaving = false;
    wiredSettingsResult;

    maxRetriesLimit = MAX_RETRIES_LIMIT;
    minutesUntilRetryLimit = MINUTES_UNTIL_RETRY_LIMIT;

    /**
     * @description Loads the saved settings, or the field defaults when none are saved yet.
     * @param {Object} result The wire result, kept so it can be refreshed after a save
     */
    @wire(getSettings)
    wiredSettings(result) {
        this.wiredSettingsResult = result;
        const { data, error } = result;
        if (data) {
            this.savedValues = {
                enabled: data.Enabled__c === true,
                maxRetries: data.MaxRetries__c,
                minutesUntilRetry: data.MinutesUntilRetry__c
            };
            this.applyValues(this.savedValues);
            this.loadError = undefined;
        } else if (error) {
            this.loadError = reduceError(error);
        }
    }

    get isLoading() {
        return !this.savedValues && !this.loadError;
    }

    get isReady() {
        return Boolean(this.savedValues);
    }

    get isPristine() {
        const saved = this.savedValues;
        return (
            !saved ||
            (saved.enabled === this.enabled &&
                saved.maxRetries === this.maxRetries &&
                saved.minutesUntilRetry === this.minutesUntilRetry)
        );
    }

    get isSaveDisabled() {
        return this.isPristine || this.isSaving;
    }

    get showDisabledWarning() {
        return this.isReady && !this.enabled;
    }

    /**
     * @description Copies a set of values into the form fields.
     * @param {Object} values The enabled, maxRetries and minutesUntilRetry values to show
     */
    applyValues(values) {
        this.enabled = values.enabled;
        this.maxRetries = values.maxRetries;
        this.minutesUntilRetry = values.minutesUntilRetry;
    }

    handleEnabledChange(event) {
        this.enabled = event.target.checked;
    }

    handleNumberChange(event) {
        const value = event.target.value;
        this[event.target.dataset.field] = value === '' || value === null ? null : Number(value);
    }

    handleCancel() {
        this.applyValues(this.savedValues);
    }

    /**
     * @description Validates the form, saves the settings and refreshes the saved values.
     */
    async handleSave() {
        const inputs = [...this.template.querySelectorAll('lightning-input')];
        const allValid = inputs.reduce((valid, input) => input.reportValidity() && valid, true);
        if (!allValid) {
            return;
        }

        this.isSaving = true;
        try {
            await saveSettings({
                enabled: this.enabled,
                maxRetries: this.maxRetries,
                minutesUntilRetry: this.minutesUntilRetry
            });
            await refreshApex(this.wiredSettingsResult);
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Settings saved', message: 'The job sequencer settings were updated.', variant: 'success' })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Settings not saved', message: reduceError(error), variant: 'error', mode: 'sticky' })
            );
        } finally {
            this.isSaving = false;
        }
    }
}
