/**
 * @description: **JobSequenceRunServiceTest** -- Unit tests for JobSequenceRunService and JobSequenceScheduledRun:
 * starting, skipping, abandoning and finishing runs, recording steps and metrics, and carrying the run Id through
 * the sequence chain.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Steps, metrics and skip counting                        |
 *
 */
@IsTest
private class JobSequenceRunServiceTest {

    /**
     * @description Returns the newest run for a frequency.
     *
     * @param frequency The frequency
     *
     * @return The run
     */
    private static Job_Sequence_Run__c latestRun(String frequency) {
        return [
                SELECT Id, Status__c, Detail__c, FinishedAt__c, DurationSeconds__c, TimesSkipped__c, LastSkippedAt__c,
                        JobsRun__c, RecordsProcessed__c, RecordsFailed__c, ErrorsLogged__c
                FROM Job_Sequence_Run__c
                WHERE Frequency__c = :frequency
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC, Name DESC
                LIMIT 1
        ];
    }

    /**
     * @description Inserts a run that is still going.
     *
     * @param frequency     The frequency
     * @param minutesAgo    How long ago it started
     *
     * @return The run
     */
    private static Job_Sequence_Run__c runningRun(String frequency, Integer minutesAgo) {
        Job_Sequence_Run__c run = new Job_Sequence_Run__c(Frequency__c = frequency, Status__c = 'Running',
                StartedAt__c = Datetime.now().addMinutes(-minutesAgo), TimesSkipped__c = 0);
        insert as system run;
        return run;
    }

    /**
     * @description Verifies a run starts and ends Completed when its sequence finds nothing more to run.
     */
    @IsTest
    static void startRunTracksTheRun() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>{'Hourly' => 1};

        Test.startTest();
        JobSequenceRunService.StartResult result = JobSequenceRunService.startRun('Hourly');
        Test.stopTest();

        Assert.isTrue(result.started, 'The run should start');
        Job_Sequence_Run__c finished = latestRun('Hourly');
        Assert.areEqual(JobSequenceRunService.STATUS_COMPLETED, finished.Status__c, 'With no real Hourly jobs the sequence ends at once');
        Assert.isNotNull(finished.DurationSeconds__c, 'The duration should be recorded');
    }

    /**
     * @description Verifies a skipped run is counted on the run still going, and a stale run is abandoned.
     */
    @IsTest
    static void startRunCountsSkipsOrAbandons() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>{'Every 5 Minutes' => 1, 'Daily' => 1};
        Job_Sequence_Run__c going = runningRun('Every 5 Minutes', 2);
        runningRun('Daily', 500);

        Test.startTest();
        JobSequenceRunService.StartResult skipped = JobSequenceRunService.startRun('Every 5 Minutes');
        JobSequenceRunService.startRun('Every 5 Minutes');
        JobSequenceRunService.StartResult started = JobSequenceRunService.startRun('Daily');
        Test.stopTest();

        Assert.isFalse(skipped.started, 'The run should not start while the previous one is going');
        Assert.isTrue(skipped.reason.contains('still running'), 'The reason should say why');
        Job_Sequence_Run__c counted = [SELECT TimesSkipped__c, LastSkippedAt__c FROM Job_Sequence_Run__c WHERE Id = :going.Id WITH SYSTEM_MODE];
        Assert.areEqual(2, counted.TimesSkipped__c, 'Both skips should be counted on the run still going');
        Assert.isNotNull(counted.LastSkippedAt__c, 'The last skip time should be set');
        Assert.areEqual(1, [SELECT COUNT() FROM Job_Sequence_Run__c WHERE Frequency__c = 'Every 5 Minutes' WITH SYSTEM_MODE], 'Skips should not create records');
        Assert.isTrue(started.started, 'A run past the timeout should not block the next');
        Assert.areEqual(1, [SELECT COUNT() FROM Job_Sequence_Run__c WHERE Frequency__c = 'Daily' AND Status__c = 'Abandoned' WITH SYSTEM_MODE],
                'The stale run should be abandoned');
    }

    /**
     * @description Verifies nothing starts, and nothing is recorded, when the sequencer is off or there are no jobs.
     */
    @IsTest
    static void startRunRecordsNothingWhenNothingCanRun() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>();

        Test.startTest();
        JobSequenceRunService.StartResult noJobs = JobSequenceRunService.startRun('Weekly');
        JobSequenceSettingsController.saveSettings(false, 10, 5, 60, 30, 30);
        JobSequenceRunService.StartResult disabled = JobSequenceRunService.startRun('Weekly');
        Test.stopTest();

        Assert.isFalse(noJobs.started, 'Nothing to run');
        Assert.isTrue(noJobs.reason.contains('no active'), 'The reason should say there was nothing to run');
        Assert.isTrue(disabled.reason.contains('turned off'), 'The reason should say the sequencer is off');
        Assert.areEqual(0, [SELECT COUNT() FROM Job_Sequence_Run__c WITH SYSTEM_MODE], 'No runs should be recorded');
    }

    /**
     * @description Verifies finishing only ends runs that are still Running, and ignores blank Ids.
     */
    @IsTest
    static void finishRunEndsOnlyRunningRuns() {
        Job_Sequence_Run__c run = runningRun('Monthly', 3);

        Test.startTest();
        JobSequenceRunService.finishRun(null, JobSequenceRunService.STATUS_FAILED, 'ignored');
        JobSequenceRunService.finishRun(run.Id, JobSequenceRunService.STATUS_FAILED, 'Boom');
        JobSequenceRunService.finishRun(run.Id, JobSequenceRunService.STATUS_COMPLETED, 'Too late');
        Test.stopTest();

        Job_Sequence_Run__c finished = latestRun('Monthly');
        Assert.areEqual(JobSequenceRunService.STATUS_FAILED, finished.Status__c, 'The first finish should win');
        Assert.areEqual('Boom', finished.Detail__c, 'The detail should be kept');
        Assert.isTrue(finished.DurationSeconds__c >= 170, 'The duration should cover the three minutes it ran');
    }

    /**
     * @description Verifies a step is recorded with the job's metrics and added to the run totals.
     */
    @IsTest
    static void recordStepAddsToRunTotals() {
        Job_Sequence_Run__c run = runningRun('Quarterly', 1);
        JobSequence js = new JobSequence();
        js.runId = run.Id;
        js.currentJob = 'JOB_A';
        js.jobType = 'DML';
        js.executionJob = 'UPDATE';
        js.stepStartedAt = Datetime.now().addSeconds(-30);
        js.recordsProcessed = 250;
        js.recordsFailed = 3;
        js.errorsLogged = 1;

        Test.startTest();
        JobSequenceRunService.recordStep(js, 'Batch', 2, 0, false);
        JobSequenceRunService.recordStep(js, 'Batch', 2, 1, true);
        JobSequenceRunService.recordStep(new JobSequence(), 'Queueable', null, null, false);
        Test.stopTest();

        Job_Sequence_Run__c totals = latestRun('Quarterly');
        Assert.areEqual(2, totals.JobsRun__c, 'Two steps belong to the run; the untracked one is ignored');
        Assert.areEqual(500, totals.RecordsProcessed__c, 'Records processed should add up');
        Assert.areEqual(6, totals.RecordsFailed__c, 'Records failed should add up');
        Assert.areEqual(2, totals.ErrorsLogged__c, 'Errors logged should add up');
        List<Job_Sequence_Run_Step__c> steps = [SELECT Status__c, DurationSeconds__c, Batches__c FROM Job_Sequence_Run_Step__c WHERE Run__c = :run.Id WITH SYSTEM_MODE ORDER BY Name];
        Assert.areEqual(2, steps.size(), 'Both steps should be recorded');
        Assert.areEqual('Failed', steps[1].Status__c, 'The failed step should say so');
        Assert.isTrue(steps[0].DurationSeconds__c >= 29, 'The step duration should be recorded');
    }

    /**
     * @description Verifies the timeout falls back to 60 minutes and follows the setting when it is saved.
     */
    @IsTest
    static void timeoutFollowsTheSetting() {
        Assert.areEqual(JobSequenceRunService.DEFAULT_TIMEOUT_MINUTES, JobSequenceRunService.getTimeoutMinutes(), 'The default should apply');
        JobSequenceSettingsController.saveSettings(true, 10, 5, 15, 30, 30);
        Assert.areEqual(15, JobSequenceRunService.getTimeoutMinutes(), 'The saved timeout should apply');
    }

    /**
     * @description Verifies the next job in a sequence carries the run Id, so the run can be finished at chain end.
     */
    @IsTest
    static void sequenceChainCarriesRunId() {
        Job_Sequence_Run__c run = runningRun('Test Only', 0);

        Test.startTest();
        JobSequenceQueueable first = new JobSequenceQueueable('Test Only', run.Id);
        JobSequenceQueueable afterLast = new JobSequenceQueueable(first.js);
        Test.stopTest();

        Assert.areEqual(run.Id, first.js.runId, 'The first job should carry the run Id');
        Assert.isNull(afterLast.js, 'There is only one Test Only job');
        Assert.areEqual(JobSequenceRunService.STATUS_COMPLETED, latestRun('Test Only').Status__c, 'The run should complete when the chain ends');
    }

    /**
     * @description Verifies a full tracked run of a DML job records its step, records and errors on the run.
     */
    @IsTest
    static void trackedQueueableRunRecordsMetrics() {
        insert as system new List<Job_Sequence_Error__c>{
                new Job_Sequence_Error__c(BatchJobId__c = 'METRICS', Exception__c = 'one'),
                new Job_Sequence_Error__c(BatchJobId__c = 'METRICS', Exception__c = 'two')
        };
        Job_Sequence_Run__c run = runningRun('Test Only', 0);
        JobSequence js = new JobSequence();
        js.runId = run.Id;
        js.allOrNone = true;
        js.currentJob = 'METRICS_DELETE';
        js.executionJob = 'DELETE';
        js.jobFrequency = 'Test Only';
        js.jobType = 'DML';
        js.query = 'SELECT Id FROM Job_Sequence_Error__c WHERE BatchJobId__c = \'METRICS\'';
        js.isBatchJob = false;
        js.handlerName = 'JobSequenceDefaultHandler';
        js.stepStartedAt = Datetime.now();

        Test.startTest();
        JobSequenceExe.executeQueueable(js);
        JobSequenceRunService.recordStep(js, 'Queueable', null, null, false);
        Test.stopTest();

        Job_Sequence_Run__c totals = latestRun('Test Only');
        Assert.areEqual(2, totals.RecordsProcessed__c, 'Both records should be counted');
        Assert.areEqual(0, totals.RecordsFailed__c, 'Nothing should fail');
        Assert.areEqual(0, [SELECT COUNT() FROM Job_Sequence_Error__c WHERE BatchJobId__c = 'METRICS' WITH SYSTEM_MODE], 'The records should be deleted');
    }

    /**
     * @description Verifies errors logged for a tracked job are counted and linked to the run.
     */
    @IsTest
    static void loggedErrorsLinkToTheRun() {
        Job_Sequence_Run__c run = runningRun('Test Only', 0);
        JobSequence js = new JobSequence();
        js.runId = run.Id;
        js.currentJob = 'BROKEN_JOB';
        js.jobFrequency = 'Test Only';

        Test.startTest();
        JobSequenceUtilities.logError(js, null, new JobSequenceException('Something broke'));
        js.logError(null, new JobSequenceException('Something else broke'), null);
        Test.stopTest();

        Assert.areEqual(2, js.errorsLogged, 'Both errors should be counted');
        Assert.areEqual(2, [SELECT COUNT() FROM Job_Sequence_Error__c WHERE Run__c = :run.Id WITH SYSTEM_MODE], 'Both errors should link to the run');
    }

    /**
     * @description Verifies the scheduled run class starts a run for its frequency.
     */
    @IsTest
    static void scheduledRunStartsItsFrequency() {
        JobSequenceSchedulerController.activeJobCountsOverride = new Map<String, Integer>{'Quarterly' => 1};

        Test.startTest();
        new JobSequenceScheduledRun('Quarterly').execute(null);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Job_Sequence_Run__c WHERE Frequency__c = 'Quarterly' WITH SYSTEM_MODE], 'A Quarterly run should be recorded');
    }
}
