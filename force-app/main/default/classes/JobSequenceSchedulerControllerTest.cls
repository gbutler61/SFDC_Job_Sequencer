/**
 * @description: **JobSequenceSchedulerControllerTest** -- Unit tests for JobSequenceSchedulerController: dashboard data,
 * scheduling, unscheduling and running frequencies now.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
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
            Assert.areEqual('JobSequence' + status.frequency, status.className, 'The class name should match the frequency');
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
        Assert.isTrue(hourly.isScheduled, 'Hourly should show as scheduled');
        Assert.isNotNull(hourly.nextFireTime, 'Hourly should have a next run time');
        Assert.areEqual(Label.Job_Sequence_Hourly_Cron, hourly.cronExpression, 'The default cron expression should be used');
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
     * @description Verifies unscheduling removes the scheduled job and unscheduling again is rejected.
     */
    @IsTest
    static void unscheduleRunRemovesScheduledJob() {
        Test.startTest();
        JobSequenceSchedulerController.scheduleRun('Weekly');
        JobSequenceSchedulerController.unscheduleRun('Weekly');
        Boolean secondUnscheduleRejected = false;
        try {
            JobSequenceSchedulerController.unscheduleRun('Weekly');
        } catch (AuraHandledException e) {
            secondUnscheduleRejected = e.getMessage().contains('not scheduled');
        }
        Test.stopTest();

        Assert.isFalse(findStatus('Weekly').isScheduled, 'Weekly should no longer be scheduled');
        Assert.isTrue(secondUnscheduleRejected, 'Unscheduling a frequency that is not scheduled should be rejected');
    }

    /**
     * @description Verifies Run Now enqueues the sequence when the frequency has active jobs.
     */
    @IsTest
    static void runNowEnqueuesSequence() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>{'Monthly' => 1};

        Test.startTest();
        Id jobId = JobSequenceSchedulerController.runNow('Monthly');
        Test.stopTest();

        Assert.isNotNull(jobId, 'A queueable job should be enqueued');
        Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE Id = :jobId WITH SYSTEM_MODE], 'The queueable job should exist');
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
        JobSequenceSettingsController.saveSettings(false, 10, 5);
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
