/**
 * @description: **JobSequenceSchedulerController** -- Apex controller for the jobSequenceScheduler LWC. Reports the
 * scheduled state of each out of the box frequency and schedules, unschedules or immediately runs them.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
public with sharing class JobSequenceSchedulerController {
    @TestVisible private static final List<String> FREQUENCIES = new List<String>{
            'Hourly', 'Daily', 'Weekly', 'Monthly', 'Quarterly', 'Yearly'
    };
    @TestVisible private static final Integer ERROR_LOOKBACK_DAYS = 7;

    //Lets tests stand in for active Sequence Job records, which cannot be inserted in a test
    @TestVisible private static Map<String, Integer> activeJobCountsOverride;

    /**
     * @description Everything the scheduler dashboard shows: whether the sequencer is enabled and one row per frequency.
     */
    public class DashboardData {
        @AuraEnabled public Boolean sequencerEnabled;
        @AuraEnabled public Integer errorLookbackDays;
        @AuraEnabled public List<FrequencyStatus> frequencies;
    }

    /**
     * @description The scheduled state, active sequence job count and recent error count for one frequency.
     */
    public class FrequencyStatus {
        @AuraEnabled public String frequency;
        @AuraEnabled public String className;
        @AuraEnabled public Boolean isScheduled;
        @AuraEnabled public String state;
        @AuraEnabled public String cronExpression;
        @AuraEnabled public Datetime nextFireTime;
        @AuraEnabled public Datetime previousFireTime;
        @AuraEnabled public Integer activeJobCount;
        @AuraEnabled public Integer recentErrorCount;
    }

    /**
     * @description Builds the dashboard data from CronTrigger, the Sequence Job records and recent Job Sequence Errors.
     * Not cacheable, because the scheduled state changes outside of this component.
     *
     * @return The dashboard data
     */
    @AuraEnabled
    public static DashboardData getDashboardData() {
        Map<String, CronTrigger> triggersByClassName = getCronTriggersByClassName();
        Map<String, Integer> activeJobCounts = getActiveJobCounts();
        Map<String, Integer> recentErrorCounts = getRecentErrorCounts();

        DashboardData data = new DashboardData();
        data.sequencerEnabled = isSequencerEnabled();
        data.errorLookbackDays = ERROR_LOOKBACK_DAYS;
        data.frequencies = new List<FrequencyStatus>();
        for (String frequency : FREQUENCIES) {
            FrequencyStatus status = new FrequencyStatus();
            status.frequency = frequency;
            status.className = getClassName(frequency);
            CronTrigger ct = triggersByClassName.get(status.className);
            status.isScheduled = ct != null;
            status.state = ct?.State;
            status.cronExpression = ct?.CronExpression;
            status.nextFireTime = ct?.NextFireTime;
            status.previousFireTime = ct?.PreviousFireTime;
            status.activeJobCount = activeJobCounts.containsKey(frequency) ? activeJobCounts.get(frequency) : 0;
            status.recentErrorCount = recentErrorCounts.containsKey(frequency) ? recentErrorCounts.get(frequency) : 0;
            data.frequencies.add(status);
        }
        System.debug('JobSequenceSchedulerController()::getDashboardData:  data: ' + data);
        return data;
    }

    /**
     * @description Schedules the frequency's schedulable class with its default cron expression from the custom labels.
     *
     * @param frequency The frequency to schedule (Hourly, Daily, Weekly, Monthly, Quarterly or Yearly)
     *
     * @return The Id of the new scheduled job
     *
     * @throws AuraHandledException when the frequency is unknown, already scheduled, or cannot be scheduled
     */
    @AuraEnabled
    public static Id scheduleRun(String frequency) {
        validateFrequency(frequency);
        String className = getClassName(frequency);
        if (getCronTriggersByClassName().containsKey(className)) {
            throw newAuraException('The ' + frequency + ' run is already scheduled.');
        }
        try {
            Id cronTriggerId = System.schedule(className, getCronExpression(frequency), (Schedulable) Type.forName(className).newInstance());
            System.debug('JobSequenceSchedulerController()::scheduleRun:  cronTriggerId: ' + cronTriggerId);
            return cronTriggerId;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'JobSequenceSchedulerController()::scheduleRun:  e: ' + e);
            throw newAuraException('The ' + frequency + ' run could not be scheduled: ' + e.getMessage());
        }
    }

    /**
     * @description Schedules every frequency that is not scheduled yet.
     *
     * @return How many frequencies were scheduled
     *
     * @throws AuraHandledException when a frequency cannot be scheduled
     */
    @AuraEnabled
    public static Integer scheduleAllRuns() {
        Map<String, CronTrigger> triggersByClassName = getCronTriggersByClassName();
        Integer scheduledCount = 0;
        for (String frequency : FREQUENCIES) {
            if (!triggersByClassName.containsKey(getClassName(frequency))) {
                scheduleRun(frequency);
                scheduledCount++;
            }
        }
        System.debug('JobSequenceSchedulerController()::scheduleAllRuns:  scheduledCount: ' + scheduledCount);
        return scheduledCount;
    }

    /**
     * @description Removes the frequency's scheduled job. Jobs that are already running are not interrupted.
     *
     * @param frequency The frequency to unschedule
     *
     * @throws AuraHandledException when the frequency is unknown or not scheduled
     */
    @AuraEnabled
    public static void unscheduleRun(String frequency) {
        validateFrequency(frequency);
        CronTrigger ct = getCronTriggersByClassName().get(getClassName(frequency));
        if (ct == null) {
            throw newAuraException('The ' + frequency + ' run is not scheduled.');
        }
        System.abortJob(ct.Id);
        System.debug('JobSequenceSchedulerController()::unscheduleRun:  abortedId: ' + ct.Id);
    }

    /**
     * @description Starts the frequency's sequence jobs now, the same way the scheduled class does.
     *
     * @param frequency The frequency to run
     *
     * @return The Id of the enqueued queueable job
     *
     * @throws AuraHandledException when the frequency is unknown, the sequencer is turned off, or the frequency has no
     * active sequence jobs
     */
    @AuraEnabled
    public static Id runNow(String frequency) {
        validateFrequency(frequency);
        if (!isSequencerEnabled()) {
            throw newAuraException('The job sequencer is turned off. Turn it on in Job Sequencer Settings first.');
        }
        Integer activeJobCount = getActiveJobCounts().get(frequency);
        if (activeJobCount == null || activeJobCount == 0) {
            throw newAuraException('There are no active ' + frequency + ' sequence jobs to run.');
        }
        Id jobId = System.enqueueJob(new JobSequenceQueueable(frequency));
        System.debug('JobSequenceSchedulerController()::runNow:  jobId: ' + jobId);
        return jobId;
    }

    /**
     * @description Finds the scheduled jobs for the out of the box schedulable classes. They are scheduled under
     * the class name, so the job name identifies them.
     *
     * @return The scheduled jobs keyed by class name
     */
    private static Map<String, CronTrigger> getCronTriggersByClassName() {
        Set<String> classNames = new Set<String>();
        for (String frequency : FREQUENCIES) {
            classNames.add(getClassName(frequency));
        }
        Map<String, CronTrigger> triggersByClassName = new Map<String, CronTrigger>();
        for (CronTrigger ct : [
                SELECT Id, State, CronExpression, NextFireTime, PreviousFireTime, CronJobDetail.Name
                FROM CronTrigger
                WHERE CronJobDetail.Name IN :classNames
                WITH SYSTEM_MODE
        ]) {
            triggersByClassName.put(ct.CronJobDetail.Name, ct);
        }
        return triggersByClassName;
    }

    /**
     * @description Counts the active Sequence Job records for each frequency.
     *
     * @return The active job counts keyed by frequency
     */
    private static Map<String, Integer> getActiveJobCounts() {
        if (activeJobCountsOverride != null) {
            return activeJobCountsOverride;
        }
        Map<String, Integer> counts = new Map<String, Integer>();
        for (Sequence_Job__mdt sj : Sequence_Job__mdt.getAll().values()) {
            if (sj.Active__c && String.isNotBlank(sj.Frequency__c)) {
                Integer current = counts.containsKey(sj.Frequency__c) ? counts.get(sj.Frequency__c) : 0;
                counts.put(sj.Frequency__c, current + 1);
            }
        }
        return counts;
    }

    /**
     * @description Counts the Job Sequence Errors logged for each frequency within the lookback window.
     *
     * @return The error counts keyed by frequency
     */
    private static Map<String, Integer> getRecentErrorCounts() {
        Datetime since = Datetime.now().addDays(-ERROR_LOOKBACK_DAYS);
        Map<String, Integer> counts = new Map<String, Integer>();
        for (AggregateResult ar : [
                SELECT JobFrequency__c frequency, COUNT(Id) errorCount
                FROM Job_Sequence_Error__c
                WHERE CreatedDate >= :since
                WITH SYSTEM_MODE
                GROUP BY JobFrequency__c
        ]) {
            counts.put((String) ar.get('frequency'), (Integer) ar.get('errorCount'));
        }
        return counts;
    }

    /**
     * @description Reads the Enabled flag the job sequencer uses at run time, falling back to the field default when no
     * settings are saved. Unlike JobSequence.sjcs, this never creates the settings record.
     *
     * @return True when the sequencer runs sequence jobs
     */
    private static Boolean isSequencerEnabled() {
        return JobSequenceSettingsController.getSettings().Enabled__c == true;
    }

    /**
     * @description Returns the out of the box schedulable class for a frequency, e.g. JobSequenceHourly.
     *
     * @param frequency The frequency
     *
     * @return The class name
     */
    private static String getClassName(String frequency) {
        return 'JobSequence' + frequency;
    }

    /**
     * @description Returns the default cron expression for a frequency from its custom label.
     *
     * @param frequency The frequency
     *
     * @return The cron expression
     */
    private static String getCronExpression(String frequency) {
        switch on frequency {
            when 'Hourly' { return Label.Job_Sequence_Hourly_Cron; }
            when 'Daily' { return Label.Job_Sequence_Daily_Cron; }
            when 'Weekly' { return Label.Job_Sequence_Weekly_Cron; }
            when 'Monthly' { return Label.Job_Sequence_Monthly_Cron; }
            when 'Quarterly' { return Label.Job_Sequence_Quarterly_Cron; }
            when else { return Label.Job_Sequence_Yearly_Cron; }
        }
    }

    /**
     * @description Rejects anything other than the out of the box frequencies.
     *
     * @param frequency The frequency passed in from the component
     *
     * @throws AuraHandledException when the frequency is not one of the out of the box frequencies
     */
    private static void validateFrequency(String frequency) {
        if (!FREQUENCIES.contains(frequency)) {
            throw newAuraException('Unknown frequency: ' + frequency);
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
