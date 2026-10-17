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
 * @description: **JobSequenceSettingsController** -- Apex controller for the jobSequenceSettings LWC. Reads and saves
 * the org-wide defaults of the Sequence Jobs Settings hierarchy custom setting.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Add Run Timeout setting                                 |
 *   |  10/16/2026 |  Gary Butler      | Add Run and Error History Days settings                 |
 *
 */
public with sharing class JobSequenceSettingsController {
    @TestVisible private static final Integer MAX_RETRIES_LIMIT = 999;
    @TestVisible private static final Integer MINUTES_UNTIL_RETRY_LIMIT = 99;
    @TestVisible private static final Integer RUN_TIMEOUT_LIMIT = 9999;
    @TestVisible private static final Integer RETENTION_DAYS_LIMIT = 9999;

    /**
     * @description Returns the org-wide default settings. When none have been saved yet, returns an unsaved record
     * populated with the field default values, which matches what the job sequencer uses at run time.
     *
     * @return The org default Sequence Jobs Settings record
     */
    @AuraEnabled(cacheable=true)
    public static Sequence_Jobs_Settings__c getSettings() {
        Sequence_Jobs_Settings__c settings = Sequence_Jobs_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = (Sequence_Jobs_Settings__c) Sequence_Jobs_Settings__c.SObjectType.newSObject(null, true);
        }
        return settings;
    }

    /**
     * @description Validates and saves the org-wide default settings, creating the org default record if it does not
     * exist yet. Runs in system mode; access is controlled by Apex class access in the Job Sequencer Admin
     * permission set.
     *
     * @param enabled           Whether the job sequencer runs sequence jobs
     * @param maxRetries        How many times a job is rescheduled when no batch slot is available (0-999)
     * @param minutesUntilRetry Minutes to wait between retry attempts (1-99)
     * @param runTimeoutMinutes Minutes a run may stay Running before the next run treats it as stopped (1-9999)
     * @param runRetentionDays  Days of Job Sequence Runs the cleanup job keeps (1-9999)
     * @param errorRetentionDays Days of Job Sequence Errors the cleanup job keeps (1-9999)
     *
     * @return The saved org default Sequence Jobs Settings record
     *
     * @throws AuraHandledException when a value is missing or out of range, or the save fails
     */
    @AuraEnabled
    public static Sequence_Jobs_Settings__c saveSettings(Boolean enabled, Integer maxRetries, Integer minutesUntilRetry,
            Integer runTimeoutMinutes, Integer runRetentionDays, Integer errorRetentionDays) {
        validateSettings(enabled, maxRetries, minutesUntilRetry, runTimeoutMinutes);
        validateRetention(runRetentionDays, 'Run History Days');
        validateRetention(errorRetentionDays, 'Error History Days');

        Sequence_Jobs_Settings__c settings = Sequence_Jobs_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = new Sequence_Jobs_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Name = 'default');
        }
        settings.Enabled__c = enabled;
        settings.MaxRetries__c = maxRetries;
        settings.MinutesUntilRetry__c = minutesUntilRetry;
        settings.RunTimeoutMinutes__c = runTimeoutMinutes;
        settings.RunRetentionDays__c = runRetentionDays;
        settings.ErrorRetentionDays__c = errorRetentionDays;

        try {
            upsert as system settings;
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'JobSequenceSettingsController()::saveSettings:  e: ' + e);
            throw newAuraException('The settings could not be saved: ' + e.getDmlMessage(0));
        }
        System.debug('JobSequenceSettingsController()::saveSettings:  settings: ' + settings);
        return settings;
    }

    /**
     * @description Checks that every setting is present and within the range its field allows.
     *
     * @param enabled           Whether the job sequencer runs sequence jobs
     * @param maxRetries        The maximum number of retries
     * @param minutesUntilRetry The minutes between retries
     * @param runTimeoutMinutes The minutes before a running run is treated as stopped
     *
     * @throws AuraHandledException when a value is missing or out of range
     */
    private static void validateSettings(Boolean enabled, Integer maxRetries, Integer minutesUntilRetry, Integer runTimeoutMinutes) {
        if (enabled == null) {
            throw newAuraException('Enabled is required.');
        }
        if (maxRetries == null || maxRetries < 0 || maxRetries > MAX_RETRIES_LIMIT) {
            throw newAuraException('Max Retries must be a whole number from 0 to ' + MAX_RETRIES_LIMIT + '.');
        }
        if (minutesUntilRetry == null || minutesUntilRetry < 1 || minutesUntilRetry > MINUTES_UNTIL_RETRY_LIMIT) {
            throw newAuraException('Minutes Until Retry must be a whole number from 1 to ' + MINUTES_UNTIL_RETRY_LIMIT + '.');
        }
        if (runTimeoutMinutes == null || runTimeoutMinutes < 1 || runTimeoutMinutes > RUN_TIMEOUT_LIMIT) {
            throw newAuraException('Run Timeout must be a whole number of minutes from 1 to ' + RUN_TIMEOUT_LIMIT + '.');
        }
    }

    /**
     * @description Checks a history-days setting is a whole number of days within range.
     *
     * @param days  The number of days
     * @param label The setting's label, for the message
     *
     * @throws AuraHandledException when the value is missing or out of range
     */
    private static void validateRetention(Integer days, String label) {
        if (days == null || days < 1 || days > RETENTION_DAYS_LIMIT) {
            throw newAuraException(label + ' must be a whole number of days from 1 to ' + RETENTION_DAYS_LIMIT + '.');
        }
    }

    /**
     * @description Builds an AuraHandledException whose message is readable both in the LWC and in Apex tests.
     *
     * @param message The message to show the user
     *
     * @return The exception, ready to throw
     */
    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
