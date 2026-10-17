/**
 * @description: **JobSequenceSchedulerControllerTest** -- Unit tests for JobSequenceSchedulerController: dashboard data,
 * scheduling (including sub-hourly slots and original per-frequency schedules), unscheduling and running now.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Sub-hourly, legacy schedules and tracked Run Now        |
 *
 */
@IsTest
private class JobSequenceSchedulerControllerTest {

    /**
     * @description Returns the dashboard row for a frequency.
     *
     * @param frequency The frequency to find
     *
     * @return The matching row, or null
     */
    private static JobSequenceSchedulerController.FrequencyStatus findStatus(String frequency) {
        for (JobSequenceSchedulerController.FrequencyStatus status : JobSequenceSchedulerController.getDashboardData().frequencies) {
            if (status.frequency == frequency) return status;
        }
        return null;
    }

    /**
     * @description Verifies the dashboard lists every frequency, unscheduled, with recent error counts.
     */
    @IsTest
    static void dashboardListsEveryFrequency() {
        insert as system new List<Job_Sequence_Error__c>{
                new Job_Sequence_Error__c(JobFrequency__c = 'Daily', Exception__c = 'Test'),
                new Job_Sequence_Error__c(JobFrequency__c = 'Daily', Exception__c = 'Test')
        };

        Test.startTest();
        JobSequenceSchedulerController.DashboardData data = JobSequenceSchedulerController.getDashboardData();
        Test.stopTest();

        Assert.isTrue(data.sequencerEnabled, 'The sequencer should default to enabled');
        Assert.areEqual(JobSequenceSchedulerController.FREQUENCIES.size(), data.frequencies.size(), 'Every frequency should be listed');
        for (JobSequenceSchedulerController.FrequencyStatus status : data.frequencies) {
            Assert.isFalse(status.isScheduled, status.frequency + ' should not be scheduled');
            Assert.areEqual(status.frequency == 'Daily' ? 2 : 0, status.recentErrorCount, 'Unexpected error count for ' + status.frequency);
        }
    }

    /**
     * @description Verifies scheduling a frequency shows it as scheduled and a second attempt is rejected.
     */
    @IsTest
    static void scheduleRunSchedulesOnce() {
        Test.startTest();
        Id cronTriggerId = JobSequenceSchedulerController.scheduleRun('Hourly');
        Boolean duplicateRejected = false;
        try {
            JobSequenceSchedulerController.scheduleRun('Hourly');
        } catch (AuraHandledException e) {
            duplicateRejected = e.getMessage().contains('already scheduled');
        }
        JobSequenceSchedulerController.FrequencyStatus hourly = findStatus('Hourly');
        Test.stopTest();

        Assert.isNotNull(cronTriggerId, 'A scheduled job should be returned');
        Assert.isTrue(duplicateRejected, 'Scheduling the same frequency twice should be rejected');
        Assert.isTrue(hourly.isFullyScheduled, 'Hourly should show as scheduled');
        Assert.isFalse(hourly.isLegacy, 'Hourly should use the single scheduled run class');
        Assert.isNotNull(hourly.nextFireTime, 'Hourly should have a next run time');
        Assert.areEqual(Label.Job_Sequence_Hourly_Cron, hourly.cronExpression, 'The default cron expression should be used');
    }

    /**
     * @description Verifies a sub-hourly frequency gets one scheduled job per slot in the hour.
     */
    @IsTest
    static void subHourlyFrequencyUsesOneJobPerSlot() {
        Test.startTest();
        JobSequenceSchedulerController.scheduleRun('Every 15 Minutes');
        JobSequenceSchedulerController.FrequencyStatus status = findStatus('Every 15 Minutes');
        Test.stopTest();

        Assert.areEqual(4, status.scheduleCount, 'Every 15 minutes needs four scheduled jobs');
        Assert.areEqual(4, status.expectedScheduleCount, 'Four slots are expected');
        Assert.isTrue(status.isFullyScheduled, 'All four slots should be scheduled');
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'Job Sequencer: Every 15 Minutes (:45)' WITH SYSTEM_MODE],
                'The :45 slot should exist');
        Assert.areEqual(12, JobSequenceSchedulerController.getSlots('Every 5 Minutes').size(), 'Every 5 minutes needs twelve slots');
    }

    /**
     * @description Verifies a frequency scheduled with the original per-frequency class is recognized, not duplicated,
     * and can be unscheduled.
     */
    @IsTest
    static void legacyScheduleIsRecognized() {
        Test.startTest();
        JobSequenceUtilities.scheduleDailyRun();
        JobSequenceSchedulerController.FrequencyStatus daily = findStatus('Daily');
        Boolean duplicateRejected = false;
        try {
            JobSequenceSchedulerController.scheduleRun('Daily');
        } catch (AuraHandledException e) {
            duplicateRejected = e.getMessage().contains('already scheduled');
        }
        JobSequenceSchedulerController.unscheduleRun('Daily');
        Test.stopTest();

        Assert.isTrue(daily.isLegacy, 'The original class schedule should be flagged');
        Assert.isTrue(daily.isFullyScheduled, 'The original class schedule counts as scheduled');
        Assert.isTrue(duplicateRejected, 'It should not be scheduled a second time');
        Assert.isFalse(findStatus('Daily').isScheduled, 'Unschedule should remove the original class schedule');
    }

    /**
     * @description Verifies scheduling all frequencies schedules each missing one exactly once.
     */
    @IsTest
    static void scheduleAllRunsSchedulesMissingFrequencies() {
        Test.startTest();
        JobSequenceSchedulerController.scheduleRun('Daily');
        Integer firstCount = JobSequenceSchedulerController.scheduleAllRuns();
        Integer secondCount = JobSequenceSchedulerController.scheduleAllRuns();
        Test.stopTest();

        Assert.areEqual(JobSequenceSchedulerController.FREQUENCIES.size() - 1, firstCount, 'Every frequency but Daily should be scheduled');
        Assert.areEqual(0, secondCount, 'Nothing should be left to schedule');
    }

    /**
     * @description Verifies unscheduling removes every slot and unscheduling again is rejected.
     */
    @IsTest
    static void unscheduleRunRemovesScheduledJobs() {
        Test.startTest();
        JobSequenceSchedulerController.scheduleRun('Every 30 Minutes');
        JobSequenceSchedulerController.unscheduleRun('Every 30 Minutes');
        Boolean secondUnscheduleRejected = false;
        try {
            JobSequenceSchedulerController.unscheduleRun('Every 30 Minutes');
        } catch (AuraHandledException e) {
            secondUnscheduleRejected = e.getMessage().contains('not scheduled');
        }
        Test.stopTest();

        Assert.isFalse(findStatus('Every 30 Minutes').isScheduled, 'Every 30 minutes should no longer be scheduled');
        Assert.isTrue(secondUnscheduleRejected, 'Unscheduling a frequency that is not scheduled should be rejected');
    }

    /**
     * @description Verifies Run Now starts a tracked run, and refuses while that run is still going.
     */
    @IsTest
    static void runNowStartsTrackedRun() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>{'Monthly' => 1};
        insert as system new Job_Sequence_Run__c(Frequency__c = 'Weekly', Status__c = JobSequenceRunService.STATUS_RUNNING, StartedAt__c = Datetime.now());

        Test.startTest();
        Id runId = JobSequenceSchedulerController.runNow('Monthly');
        JobSequenceSchedulerController.activeJobCountsOverride.put('Weekly', 1);
        Boolean stillRunningRejected = false;
        try {
            JobSequenceSchedulerController.runNow('Weekly');
        } catch (AuraHandledException e) {
            stillRunningRejected = e.getMessage().contains('still running');
        }
        Test.stopTest();

        Assert.isNotNull(runId, 'A run should be created');
        Assert.areEqual('Monthly', [SELECT Frequency__c FROM Job_Sequence_Run__c WHERE Id = :runId WITH SYSTEM_MODE].Frequency__c, 'The run should be for Monthly');
        Assert.isTrue(stillRunningRejected, 'Run Now should be refused while the previous run is still going');
    }

    /**
     * @description Verifies Run Now is rejected when the frequency has no active jobs or the sequencer is turned off.
     */
    @IsTest
    static void runNowRejectsWhenNothingCanRun() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>();

        Test.startTest();
        Boolean noJobsRejected = false;
        try {
            JobSequenceSchedulerController.runNow('Yearly');
        } catch (AuraHandledException e) {
            noJobsRejected = e.getMessage().contains('no active');
        }

        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>{'Yearly' => 1};
        JobSequenceSettingsController.saveSettings(false, 10, 5, 60, 30, 30);
        Boolean disabledRejected = false;
        try {
            JobSequenceSchedulerController.runNow('Yearly');
        } catch (AuraHandledException e) {
            disabledRejected = e.getMessage().contains('turned off');
        }
        Test.stopTest();

        Assert.isTrue(noJobsRejected, 'Run Now should be rejected when there are no active jobs');
        Assert.isTrue(disabledRejected, 'Run Now should be rejected when the sequencer is turned off');
        Assert.isFalse(JobSequenceSchedulerController.getDashboardData().sequencerEnabled, 'The dashboard should report the sequencer as off');
    }

    /**
     * @description Verifies unknown frequencies are rejected by every action.
     */
    @IsTest
    static void unknownFrequencyIsRejected() {
        Integer rejected = 0;
        Test.startTest();
        try { JobSequenceSchedulerController.scheduleRun('Test Only'); } catch (AuraHandledException e) { rejected++; }
        try { JobSequenceSchedulerController.unscheduleRun('Test Only'); } catch (AuraHandledException e) { rejected++; }
        try { JobSequenceSchedulerController.runNow('Test Only'); } catch (AuraHandledException e) { rejected++; }
        Test.stopTest();

        Assert.areEqual(3, rejected, 'Every action should reject an unknown frequency');
    }

    /**
     * @description Verifies the utilities scheduling no longer throws (or double schedules) when a run already exists.
     */
    @IsTest
    static void setupScheduledRunSkipsExistingSchedule() {
        Test.startTest();
        JobSequenceUtilities.scheduleHourlyRun();
        JobSequenceUtilities.scheduleHourlyRun();
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'JobSequenceHourly' WITH SYSTEM_MODE],
                'Hourly should be scheduled exactly once');
    }
}
