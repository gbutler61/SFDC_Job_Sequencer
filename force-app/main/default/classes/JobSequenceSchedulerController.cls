/**
 * @description: **JobSequenceSchedulerController** -- Apex controller for the jobSequenceScheduler LWC. Reports the
 * scheduled state of each frequency (every 5 minutes through yearly) and schedules, unschedules or immediately runs
 * them. Sub-hourly frequencies use one scheduled job per slot in the hour, because a Salesforce cron expression can
 * name only one minute.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Sub-hourly frequencies; single JobSequenceScheduledRun  |
 *
 */
public with sharing class JobSequenceSchedulerController {
    @TestVisible private static final List<String> FREQUENCIES = new List<String>{
            'Every 5 Minutes', 'Every 10 Minutes', 'Every 15 Minutes', 'Every 30 Minutes',
            'Hourly', 'Daily', 'Weekly', 'Monthly', 'Quarterly', 'Yearly'
    };
    //Minutes between runs for the sub-hourly frequencies
    @TestVisible private static final Map<String, Integer> MINUTE_INTERVALS = new Map<String, Integer>{
            'Every 5 Minutes' => 5, 'Every 10 Minutes' => 10, 'Every 15 Minutes' => 15, 'Every 30 Minutes' => 30
    };
    //Frequencies that the original package scheduled with one class each (JobSequenceHourly, ...)
    private static final Set<String> LEGACY_FREQUENCIES = new Set<String>{'Hourly', 'Daily', 'Weekly', 'Monthly', 'Quarterly', 'Yearly'};
    @TestVisible private static final String JOB_NAME_PREFIX = 'Job Sequencer: ';
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
        @AuraEnabled public Boolean isScheduled;
        @AuraEnabled public Boolean isFullyScheduled;
        @AuraEnabled public Boolean isLegacy;
        @AuraEnabled public Boolean isHealthy;
        @AuraEnabled public Integer scheduleCount;
        @AuraEnabled public Integer expectedScheduleCount;
        @AuraEnabled public String state;
        @AuraEnabled public String cronExpression;
        @AuraEnabled public Datetime nextFireTime;
        @AuraEnabled public Datetime previousFireTime;
        @AuraEnabled public Integer activeJobCount;
        @AuraEnabled public Integer recentErrorCount;
    }

    /**
     * @description One scheduled job slot of a frequency: its job name and cron expression.
     */
    @TestVisible
    private class Slot {
        public String jobName;
        public String cronExpression;

        /**
         * @description Creates a slot.
         *
         * @param jobName        The scheduled job name
         * @param cronExpression The cron expression
         */
        public Slot(String jobName, String cronExpression) {
            this.jobName = jobName;
            this.cronExpression = cronExpression;
        }
    }

    /**
     * @description Builds the dashboard data from CronTrigger, the Sequence Job records and recent Job Sequence Errors.
     * Not cacheable, because the scheduled state changes outside of this component.
     *
     * @return The dashboard data
     */
    @AuraEnabled
    public static DashboardData getDashboardData() {
        Map<String, List<CronTrigger>> triggersByFrequency = getCronTriggersByFrequency();
        Map<String, Integer> activeJobCounts = getActiveJobCounts();
        Map<String, Integer> recentErrorCounts = getRecentErrorCounts();
        Set<String> healthyStates = new Set<String>{'WAITING', 'ACQUIRED', 'EXECUTING'};

        DashboardData data = new DashboardData();
        data.sequencerEnabled = isSequencerEnabled();
        data.errorLookbackDays = ERROR_LOOKBACK_DAYS;
        data.frequencies = new List<FrequencyStatus>();
        for (String frequency : FREQUENCIES) {
            List<CronTrigger> triggers = triggersByFrequency.containsKey(frequency) ? triggersByFrequency.get(frequency) : new List<CronTrigger>();
            FrequencyStatus status = new FrequencyStatus();
            status.frequency = frequency;
            status.scheduleCount = triggers.size();
            status.expectedScheduleCount = getSlots(frequency).size();
            status.isScheduled = !triggers.isEmpty();
            status.isLegacy = false;
            status.isHealthy = true;
            for (CronTrigger ct : triggers) {
                status.isLegacy = status.isLegacy || !ct.CronJobDetail.Name.startsWith(JOB_NAME_PREFIX);
                if (!healthyStates.contains(ct.State)) {
                    status.isHealthy = false;
                    status.state = ct.State;
                }
                if (ct.NextFireTime != null && (status.nextFireTime == null || ct.NextFireTime < status.nextFireTime)) {
                    status.nextFireTime = ct.NextFireTime;
                }
                if (ct.PreviousFireTime != null && (status.previousFireTime == null || ct.PreviousFireTime > status.previousFireTime)) {
                    status.previousFireTime = ct.PreviousFireTime;
                }
            }
            status.isFullyScheduled = status.isLegacy ? status.isScheduled : status.scheduleCount >= status.expectedScheduleCount;
            status.cronExpression = triggers.size() == 1 ? triggers[0].CronExpression : null;
            status.activeJobCount = activeJobCounts.containsKey(frequency) ? activeJobCounts.get(frequency) : 0;
            status.recentErrorCount = recentErrorCounts.containsKey(frequency) ? recentErrorCounts.get(frequency) : 0;
            data.frequencies.add(status);
        }
        System.debug('JobSequenceSchedulerController()::getDashboardData:  data: ' + data);
        return data;
    }

    /**
     * @description Schedules every missing slot of a frequency with the single JobSequenceScheduledRun class. A
     * frequency still scheduled with its original per-frequency class counts as scheduled.
     *
     * @param frequency The frequency to schedule
     *
     * @return The Id of the first scheduled job created
     *
     * @throws AuraHandledException when the frequency is unknown, already scheduled, or cannot be scheduled
     */
    @AuraEnabled
    public static Id scheduleRun(String frequency) {
        validateFrequency(frequency);
        List<CronTrigger> existing = getCronTriggersByFrequency().get(frequency);
        Set<String> existingNames = new Set<String>();
        for (CronTrigger ct : existing == null ? new List<CronTrigger>() : existing) {
            existingNames.add(ct.CronJobDetail.Name);
        }
        if (existing != null && (existingNames.contains('JobSequence' + frequency) || existingNames.size() >= getSlots(frequency).size())) {
            throw newAuraException('The ' + frequency + ' run is already scheduled.');
        }

        Id firstId;
        try {
            for (Slot slot : getSlots(frequency)) {
                if (existingNames.contains(slot.jobName)) continue;
                Id cronTriggerId = System.schedule(slot.jobName, slot.cronExpression, new JobSequenceScheduledRun(frequency));
                firstId = firstId == null ? cronTriggerId : firstId;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'JobSequenceSchedulerController()::scheduleRun:  e: ' + e);
            throw newAuraException('The ' + frequency + ' run could not be scheduled: ' + e.getMessage());
        }
        System.debug('JobSequenceSchedulerController()::scheduleRun:  firstId: ' + firstId);
        return firstId;
    }

    /**
     * @description Schedules every frequency that is not fully scheduled yet.
     *
     * @return How many frequencies were scheduled
     *
     * @throws AuraHandledException when a frequency cannot be scheduled
     */
    @AuraEnabled
    public static Integer scheduleAllRuns() {
        Integer scheduledCount = 0;
        for (FrequencyStatus status : getDashboardData().frequencies) {
            if (!status.isFullyScheduled) {
                scheduleRun(status.frequency);
                scheduledCount++;
            }
        }
        System.debug('JobSequenceSchedulerController()::scheduleAllRuns:  scheduledCount: ' + scheduledCount);
        return scheduledCount;
    }

    /**
     * @description Removes every scheduled job of a frequency, including one made with the original per-frequency
     * class. Runs already in progress are not interrupted.
     *
     * @param frequency The frequency to unschedule
     *
     * @throws AuraHandledException when the frequency is unknown or not scheduled
     */
    @AuraEnabled
    public static void unscheduleRun(String frequency) {
        validateFrequency(frequency);
        List<CronTrigger> triggers = getCronTriggersByFrequency().get(frequency);
        if (triggers == null || triggers.isEmpty()) {
            throw newAuraException('The ' + frequency + ' run is not scheduled.');
        }
        for (CronTrigger ct : triggers) {
            System.abortJob(ct.Id);
        }
        System.debug('JobSequenceSchedulerController()::unscheduleRun:  abortedCount: ' + triggers.size());
    }

    /**
     * @description Starts the frequency's sequence now, through the same run service the schedules use, so it is
     * tracked as a Job Sequence Run and refused while the previous run is still going.
     *
     * @param frequency The frequency to run
     *
     * @return The Id of the Job Sequence Run
     *
     * @throws AuraHandledException when the frequency is unknown, the sequencer is turned off, the frequency has no
     * active sequence jobs, or the previous run is still going
     */
    @AuraEnabled
    public static Id runNow(String frequency) {
        validateFrequency(frequency);
        if (!isSequencerEnabled()) {
            throw newAuraException('The job sequencer is turned off. Turn it on in Job Sequencer Settings first.');
        }
        if (getActiveJobCount(frequency) == 0) {
            throw newAuraException('There are no active ' + frequency + ' sequence jobs to run.');
        }
        JobSequenceRunService.StartResult result = JobSequenceRunService.startRun(frequency);
        if (!result.started) {
            throw newAuraException('The ' + frequency + ' sequence was not started because ' + result.reason);
        }
        System.debug('JobSequenceSchedulerController()::runNow:  runId: ' + result.run.Id);
        return result.run.Id;
    }

    /**
     * @description Counts the active Sequence Job records for one frequency.
     *
     * @param frequency The frequency
     *
     * @return The number of active jobs
     */
    public static Integer getActiveJobCount(String frequency) {
        Integer count = getActiveJobCounts().get(frequency);
        return count == null ? 0 : count;
    }

    /**
     * @description Returns the scheduled job slots for a frequency: one per run in the hour for sub-hourly
     * frequencies, otherwise one using the frequency's cron custom label.
     *
     * @param frequency The frequency
     *
     * @return The slots
     */
    @TestVisible
    private static List<Slot> getSlots(String frequency) {
        List<Slot> slots = new List<Slot>();
        Integer interval = MINUTE_INTERVALS.get(frequency);
        if (interval == null) {
            slots.add(new Slot(JOB_NAME_PREFIX + frequency, getCronExpression(frequency)));
            return slots;
        }
        for (Integer minute = 0; minute < 60; minute += interval) {
            String minuteLabel = minute < 10 ? '0' + minute : String.valueOf(minute);
            slots.add(new Slot(JOB_NAME_PREFIX + frequency + ' (:' + minuteLabel + ')', '0 ' + minute + ' * * * ?'));
        }
        return slots;
    }

    /**
     * @description Finds the scheduled jobs for every frequency: those this package names "Job Sequencer: ..." and
     * those scheduled under the original class names (e.g. JobSequenceHourly).
     *
     * @return The scheduled jobs keyed by frequency
     */
    private static Map<String, List<CronTrigger>> getCronTriggersByFrequency() {
        Map<String, String> frequencyByLegacyName = new Map<String, String>();
        for (String frequency : LEGACY_FREQUENCIES) {
            frequencyByLegacyName.put('JobSequence' + frequency, frequency);
        }
        Set<String> legacyNames = frequencyByLegacyName.keySet();
        String namePattern = JOB_NAME_PREFIX + '%';

        Map<String, List<CronTrigger>> triggersByFrequency = new Map<String, List<CronTrigger>>();
        for (CronTrigger ct : [
                SELECT Id, State, CronExpression, NextFireTime, PreviousFireTime, CronJobDetail.Name
                FROM CronTrigger
                WHERE CronJobDetail.Name LIKE :namePattern OR CronJobDetail.Name IN :legacyNames
                WITH SYSTEM_MODE
        ]) {
            String name = ct.CronJobDetail.Name;
            String frequency = frequencyByLegacyName.containsKey(name)
                    ? frequencyByLegacyName.get(name)
                    : name.removeStart(JOB_NAME_PREFIX).substringBefore(' (:');
            if (!FREQUENCIES.contains(frequency)) continue;
            if (!triggersByFrequency.containsKey(frequency)) {
                triggersByFrequency.put(frequency, new List<CronTrigger>());
            }
            triggersByFrequency.get(frequency).add(ct);
        }
        return triggersByFrequency;
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
     * @description Returns the default cron expression for an hourly-or-longer frequency from its custom label.
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
     * @description Rejects anything other than the supported frequencies.
     *
     * @param frequency The frequency passed in from the component
     *
     * @throws AuraHandledException when the frequency is not supported
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
