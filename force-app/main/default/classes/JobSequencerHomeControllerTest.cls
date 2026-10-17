/**
 * @description: **JobSequencerHomeControllerTest** -- Unit tests for JobSequencerHomeController: schedule metrics,
 * error trends and lists, and recent runs.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Run metrics, slowest jobs and cleanup warning           |
 *
 */
@IsTest
private class JobSequencerHomeControllerTest {

    /**
     * @description Verifies the metrics when nothing is scheduled and no errors exist.
     */
    @IsTest
    static void homeDataWithNoActivity() {
        Test.startTest();
        JobSequencerHomeController.HomeData data = JobSequencerHomeController.getHomeData();
        Test.stopTest();

        Assert.isTrue(data.sequencerEnabled, 'The sequencer should default to enabled');
        Assert.areEqual(0, data.scheduledCount, 'Nothing should be scheduled');
        Assert.areEqual(JobSequenceSchedulerController.FREQUENCIES.size(), data.frequencyCount, 'Every frequency should be counted');
        Assert.isNull(data.nextRunTime, 'There should be no next run');
        Assert.areEqual(0, data.errorsLast7Days, 'There should be no recent errors');
        Assert.areEqual(JobSequencerHomeController.CHART_DAYS, data.errorsByDay.size(), 'The chart should have a bar for every day');
        Assert.areEqual(Date.today(), data.errorsByDay[data.errorsByDay.size() - 1].day, 'The last bar should be today');
        Assert.isTrue(data.recentErrors.isEmpty(), 'There should be no recent errors listed');
        Assert.isTrue(data.topFailingJobs.isEmpty(), 'There should be no failing jobs');
        Assert.areEqual(JobSequencerHomeController.CHART_DAYS, data.recordsByDay.size(), 'The records chart should have a bar for every day');
        Assert.isTrue(data.frequencyStats.isEmpty(), 'No frequency has run');
        Assert.isTrue(data.cleanupNotScheduled, 'The packaged cleanup jobs are active but Daily is not scheduled');
    }

    /**
     * @description Verifies run and step metrics are summarized per day, per frequency and per job.
     */
    @IsTest
    static void homeDataSummarizesRunMetrics() {
        Datetime started = Datetime.now().addMinutes(-10);
        Job_Sequence_Run__c run = new Job_Sequence_Run__c(Frequency__c = 'Every 15 Minutes', Status__c = 'Completed',
                StartedAt__c = started, FinishedAt__c = started.addSeconds(90), DurationSeconds__c = 90, JobsRun__c = 2,
                RecordsProcessed__c = 400, RecordsFailed__c = 4, TimesSkipped__c = 3, ErrorsLogged__c = 1);
        insert as system run;
        insert as system new List<Job_Sequence_Run_Step__c>{
                new Job_Sequence_Run_Step__c(Run__c = run.Id, SequenceJob__c = 'SLOW_JOB', StartedAt__c = started, DurationSeconds__c = 80, RecordsProcessed__c = 300),
                new Job_Sequence_Run_Step__c(Run__c = run.Id, SequenceJob__c = 'FAST_JOB', StartedAt__c = started, DurationSeconds__c = 10, RecordsProcessed__c = 100)
        };

        Test.startTest();
        JobSequenceSchedulerController.scheduleRun('Daily');
        JobSequencerHomeController.HomeData data = JobSequencerHomeController.getHomeData();
        Test.stopTest();

        Assert.areEqual(400, data.recordsByDay[data.recordsByDay.size() - 1].value, 'Today should show the records processed');
        Assert.areEqual(1, data.frequencyStats.size(), 'One frequency ran');
        Assert.areEqual(3, data.frequencyStats[0].timesSkipped, 'The skips should be summed');
        Assert.areEqual(90, data.frequencyStats[0].averageSeconds, 'The average duration should be reported');
        Assert.areEqual('SLOW_JOB', data.slowestJobs[0].jobName, 'The slowest job should be first');
        Assert.areEqual(400, data.recentRuns[0].recordsProcessed, 'The recent run should show its records');
        Assert.isFalse(data.cleanupNotScheduled, 'Daily is scheduled, so there is no warning');
    }

    /**
     * @description Verifies scheduled frequencies are counted and the soonest next run is reported.
     */
    @IsTest
    static void homeDataReportsSchedules() {
        Test.startTest();
        JobSequenceSchedulerController.scheduleRun('Hourly');
        JobSequenceSchedulerController.scheduleRun('Yearly');
        JobSequencerHomeController.HomeData data = JobSequencerHomeController.getHomeData();
        Test.stopTest();

        Assert.areEqual(2, data.scheduledCount, 'Two frequencies should be scheduled');
        Assert.areEqual('Hourly', data.nextRunFrequency, 'The hourly run should be the soonest');
        Assert.isNotNull(data.nextRunTime, 'The next run time should be set');
    }

    /**
     * @description Verifies errors are counted per day, ranked by job, and listed newest first.
     */
    @IsTest
    static void homeDataSummarizesErrors() {
        List<Job_Sequence_Error__c> errors = new List<Job_Sequence_Error__c>{
                new Job_Sequence_Error__c(JobName__c = 'JOB_A', JobFrequency__c = 'Daily', Exception__c = 'First'),
                new Job_Sequence_Error__c(JobName__c = 'JOB_A', JobFrequency__c = 'Daily', Exception__c = 'Second'),
                new Job_Sequence_Error__c(JobName__c = 'JOB_B', JobFrequency__c = 'Hourly', Exception__c = 'x'.repeat(500))
        };
        insert as system errors;

        Test.startTest();
        JobSequencerHomeController.HomeData data = JobSequencerHomeController.getHomeData();
        Test.stopTest();

        Assert.areEqual(3, data.errorsLast7Days, 'All three errors are from today');
        Assert.areEqual(0, data.errorsPrior7Days, 'No errors are from the prior week');
        Assert.areEqual(3, data.errorsByDay[data.errorsByDay.size() - 1].value, 'The bar for today should count all three');
        Assert.areEqual('JOB_A', data.topFailingJobs[0].jobName, 'JOB_A has the most errors');
        Assert.areEqual(2, data.topFailingJobs[0].errorCount, 'JOB_A should have two errors');
        Assert.areEqual(3, data.recentErrors.size(), 'All three errors should be listed');
        for (JobSequencerHomeController.RecentError re : data.recentErrors) {
            Assert.isTrue(re.exceptionPreview.length() <= 160, 'The exception preview should be shortened');
        }
    }

    /**
     * @description Verifies Job Sequence Runs are listed with their status and skip count.
     */
    @IsTest
    static void homeDataListsRecentRuns() {
        insert as system new Job_Sequence_Run__c(Frequency__c = 'Every 5 Minutes', Status__c = 'Completed',
                StartedAt__c = Datetime.now(), FinishedAt__c = Datetime.now(), TimesSkipped__c = 2);

        Test.startTest();
        JobSequencerHomeController.HomeData data = JobSequencerHomeController.getHomeData();
        Test.stopTest();

        Assert.areEqual(1, data.recentRuns.size(), 'The run should be listed');
        Assert.areEqual('Completed', data.recentRuns[0].status, 'The run status should be shown');
        Assert.areEqual(2, data.recentRuns[0].timesSkipped, 'The skip count should be shown');
        Assert.areEqual('Every 5 Minutes', data.recentRuns[0].frequency, 'The run frequency should be shown');
    }
}
