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
 *
 */
public with sharing class JobSequenceSettingsController {
    @TestVisible private static final Integer MAX_RETRIES_LIMIT = 999;
    @TestVisible private static final Integer MINUTES_UNTIL_RETRY_LIMIT = 99;

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
     *
     * @return The saved org default Sequence Jobs Settings record
     *
     * @throws AuraHandledException when a value is missing or out of range, or the save fails
     */
    @AuraEnabled
    public static Sequence_Jobs_Settings__c saveSettings(Boolean enabled, Integer maxRetries, Integer minutesUntilRetry) {
        validateSettings(enabled, maxRetries, minutesUntilRetry);

        Sequence_Jobs_Settings__c settings = Sequence_Jobs_Settings__c.getOrgDefaults();
        if (settings == null || settings.Id == null) {
            settings = new Sequence_Jobs_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Name = 'default');
        }
        settings.Enabled__c = enabled;
        settings.MaxRetries__c = maxRetries;
        settings.MinutesUntilRetry__c = minutesUntilRetry;

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
     *
     * @throws AuraHandledException when a value is missing or out of range
     */
    private static void validateSettings(Boolean enabled, Integer maxRetries, Integer minutesUntilRetry) {
        if (enabled == null) {
            throw newAuraException('Enabled is required.');
        }
        if (maxRetries == null || maxRetries < 0 || maxRetries > MAX_RETRIES_LIMIT) {
            throw newAuraException('Max Retries must be a whole number from 0 to ' + MAX_RETRIES_LIMIT + '.');
        }
        if (minutesUntilRetry == null || minutesUntilRetry < 1 || minutesUntilRetry > MINUTES_UNTIL_RETRY_LIMIT) {
            throw newAuraException('Minutes Until Retry must be a whole number from 1 to ' + MINUTES_UNTIL_RETRY_LIMIT + '.');
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
