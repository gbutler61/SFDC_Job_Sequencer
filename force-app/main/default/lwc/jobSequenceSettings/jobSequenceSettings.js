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
 * @description jobSequenceSettings -- Edits the org-wide defaults of the Sequence Jobs Settings custom setting
 * (Enabled, retries, Run Timeout and history days). Replaces the redirect to the Classic custom settings page.
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
// RunTimeoutMinutes__c is Number(4, 0)
const RUN_TIMEOUT_LIMIT = 9999;
const DEFAULT_RUN_TIMEOUT = 60;
// RunRetentionDays__c and ErrorRetentionDays__c are Number(4, 0)
const RETENTION_LIMIT = 9999;
const DEFAULT_RETENTION_DAYS = 30;

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
    runTimeoutMinutes;
    runRetentionDays;
    errorRetentionDays;
    savedValues;
    loadError;
    isSaving = false;
    wiredSettingsResult;

    maxRetriesLimit = MAX_RETRIES_LIMIT;
    minutesUntilRetryLimit = MINUTES_UNTIL_RETRY_LIMIT;
    runTimeoutLimit = RUN_TIMEOUT_LIMIT;
    retentionLimit = RETENTION_LIMIT;

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
                minutesUntilRetry: data.MinutesUntilRetry__c,
                // Settings saved before 1.2.0 have no timeout yet; show the default the sequencer uses
                runTimeoutMinutes: data.RunTimeoutMinutes__c ?? DEFAULT_RUN_TIMEOUT,
                runRetentionDays: data.RunRetentionDays__c ?? DEFAULT_RETENTION_DAYS,
                errorRetentionDays: data.ErrorRetentionDays__c ?? DEFAULT_RETENTION_DAYS
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
                saved.minutesUntilRetry === this.minutesUntilRetry &&
                saved.runTimeoutMinutes === this.runTimeoutMinutes &&
                saved.runRetentionDays === this.runRetentionDays &&
                saved.errorRetentionDays === this.errorRetentionDays)
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
     * @param {Object} values The enabled, maxRetries, minutesUntilRetry and runTimeoutMinutes values to show
     */
    applyValues(values) {
        this.enabled = values.enabled;
        this.maxRetries = values.maxRetries;
        this.minutesUntilRetry = values.minutesUntilRetry;
        this.runTimeoutMinutes = values.runTimeoutMinutes;
        this.runRetentionDays = values.runRetentionDays;
        this.errorRetentionDays = values.errorRetentionDays;
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
                minutesUntilRetry: this.minutesUntilRetry,
                runTimeoutMinutes: this.runTimeoutMinutes,
                runRetentionDays: this.runRetentionDays,
                errorRetentionDays: this.errorRetentionDays
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
