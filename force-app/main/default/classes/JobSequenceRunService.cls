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
 * @description: **JobSequenceRunService** -- Starts and finishes runs of a frequency's job sequence and records their
 * metrics. Each run is a Job Sequence Run with one Job Sequence Run Step per sequence job. A new run is not started
 * while the previous run of the same frequency is still going (the running run's Times Skipped is counted instead),
 * unless that run has exceeded the Run Timeout setting.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Run steps and metrics; count skips; cleanup via jobs    |
 *   |  10/17/2026 |  Gary Butler      | Standalone runs of one One Time job                     |
 *
 */
public without sharing class JobSequenceRunService {
    public static final String STATUS_RUNNING = 'Running';
    public static final String STATUS_COMPLETED = 'Completed';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_DISABLED = 'Disabled';
    public static final String STATUS_ABANDONED = 'Abandoned';

    @TestVisible private static final Integer DEFAULT_TIMEOUT_MINUTES = 60;
    public static final String ONE_TIME = 'One Time';
    private static final Integer DETAIL_LENGTH = 255;

    /**
     * @description The outcome of asking to start a run.
     */
    public class StartResult {
        public Boolean started = false;
        public Job_Sequence_Run__c run;
        public String reason;
    }

    /**
     * @description Starts a run of the frequency's job sequence. Nothing is started (or recorded) when the sequencer
     * is turned off or the frequency has no active jobs. When the previous run is still going, its Times Skipped is
     * counted and nothing is started.
     *
     * @param frequency The frequency to run
     *
     * @return Whether the run started; the new run, or the run still going when it was skipped; and why not
     */
    public static StartResult startRun(String frequency) {
        return start(frequency, null, null);
    }

    /**
     * @description Starts a standalone run of one active One Time sequence job: only that job runs, and the run ends
     * when it finishes. Refused, like any run, while a One Time run is still going.
     *
     * @param developerName The job's API name
     *
     * @return Whether the run started; the new run, or the run still going; and why not
     */
    public static StartResult startStandaloneRun(String developerName) {
        List<Sequence_Job__mdt> jobs = [
                SELECT DeveloperName, MasterLabel, Frequency__c, Active__c FROM Sequence_Job__mdt
                WHERE DeveloperName = :developerName WITH SYSTEM_MODE
        ];
        if (jobs.isEmpty() || jobs[0].Frequency__c != ONE_TIME) {
            StartResult refused = new StartResult();
            refused.reason = jobs.isEmpty() ? 'no sequence job named ' + developerName + ' exists.'
                    : 'only One Time jobs can be run on their own; ' + developerName + ' is ' + jobs[0].Frequency__c + '.';
            return refused;
        }
        if (jobs[0].Active__c != true) {
            StartResult refused = new StartResult();
            refused.reason = jobs[0].MasterLabel + ' is not active. Activate it first.';
            return refused;
        }
        return start(ONE_TIME, developerName, 'Standalone run of ' + jobs[0].MasterLabel + ' (' + developerName + ').');
    }

    /**
     * @description Starts a run of the frequency's sequence, or of one standalone job in it.
     *
     * @param frequency     The frequency
     * @param developerName The standalone job's API name, or null to run the whole sequence
     * @param detail        Recorded on the run, or null
     *
     * @return Whether the run started; the new run, or the run still going; and why not
     */
    private static StartResult start(String frequency, String developerName, String detail) {
        StartResult result = new StartResult();
        Datetime now = Datetime.now();

        if (JobSequenceSettingsController.getSettings().Enabled__c != true) {
            result.reason = 'the job sequencer is turned off.';
            return result;
        }
        if (JobSequenceSchedulerController.getActiveJobCount(frequency) == 0) {
            result.reason = 'there are no active sequence jobs for this frequency.';
            return result;
        }

        Job_Sequence_Run__c stillRunning = findRunningRun(frequency, now);
        if (stillRunning != null) {
            stillRunning.TimesSkipped__c = (stillRunning.TimesSkipped__c == null ? 0 : stillRunning.TimesSkipped__c) + 1;
            stillRunning.LastSkippedAt__c = now;
            update as system stillRunning;
            result.run = stillRunning;
            result.reason = stillRunning.Name + ' is still running.';
            System.debug('JobSequenceRunService()::start:  skippedFor: ' + stillRunning.Name);
            return result;
        }

        Job_Sequence_Run__c run = new Job_Sequence_Run__c(
                Frequency__c = frequency,
                Status__c = STATUS_RUNNING,
                StartedAt__c = now,
                JobsRun__c = 0,
                RecordsProcessed__c = 0,
                RecordsFailed__c = 0,
                ErrorsLogged__c = 0,
                TimesSkipped__c = 0,
                Detail__c = detail
        );
        insert as system run;
        System.enqueueJob(developerName == null ? new JobSequenceQueueable(frequency, run.Id)
                : new JobSequenceQueueable(frequency, developerName, run.Id));
        result.started = true;
        result.run = run;
        System.debug('JobSequenceRunService()::start:  run: ' + run);
        return result;
    }

    /**
     * @description Records one sequence job's step in its run and adds its metrics to the run totals. Jobs that are
     * not part of a tracked run (started outside the run service) are ignored.
     *
     * @param js            The job sequence that finished, carrying its metrics
     * @param mode          Batch or Queueable
     * @param batches       Batches run, for batch jobs; otherwise null
     * @param batchesFailed Batches that ended in an unhandled error, for batch jobs; otherwise null
     * @param failed        True when the job stopped on an error
     */
    public static void recordStep(JobSequence js, String mode, Integer batches, Integer batchesFailed, Boolean failed) {
        if (js == null || js.runId == null) {
            return;
        }
        Datetime now = Datetime.now();
        Datetime started = js.stepStartedAt == null ? now : js.stepStartedAt;
        Job_Sequence_Run_Step__c step = new Job_Sequence_Run_Step__c(
                Run__c = js.runId,
                SequenceJob__c = js.currentJob,
                JobLabel__c = js.sj == null ? null : js.sj.MasterLabel,
                Order__c = js.sj == null ? null : js.sj.Order__c,
                JobType__c = js.jobType,
                ExecutionJob__c = js.executionJob?.left(80),
                Mode__c = mode,
                Status__c = failed == true ? STATUS_FAILED : STATUS_COMPLETED,
                StartedAt__c = started,
                FinishedAt__c = now,
                DurationSeconds__c = secondsBetween(started, now),
                RecordsProcessed__c = js.recordsProcessed,
                RecordsFailed__c = js.recordsFailed,
                ErrorsLogged__c = js.errorsLogged,
                Batches__c = batches,
                BatchesFailed__c = batchesFailed
        );
        insert as system step;

        List<Job_Sequence_Run__c> runs = [
                SELECT Id, JobsRun__c, RecordsProcessed__c, RecordsFailed__c, ErrorsLogged__c
                FROM Job_Sequence_Run__c
                WHERE Id = :js.runId
                WITH SYSTEM_MODE
                FOR UPDATE
        ];
        if (!runs.isEmpty()) {
            Job_Sequence_Run__c run = runs[0];
            run.JobsRun__c = zeroIfNull(run.JobsRun__c) + 1;
            run.RecordsProcessed__c = zeroIfNull(run.RecordsProcessed__c) + js.recordsProcessed;
            run.RecordsFailed__c = zeroIfNull(run.RecordsFailed__c) + js.recordsFailed;
            run.ErrorsLogged__c = zeroIfNull(run.ErrorsLogged__c) + js.errorsLogged;
            update as system run;
        }
        System.debug('JobSequenceRunService()::recordStep:  step: ' + step);
    }

    /**
     * @description Ends a run that is still Running and records its duration. Runs that already ended, and blank Ids
     * (sequences started outside the run service, e.g. by the original per-frequency schedulable classes), are
     * ignored.
     *
     * @param runId  The run to end
     * @param status How it ended
     * @param detail Why, or null
     */
    public static void finishRun(Id runId, String status, String detail) {
        if (runId == null) {
            return;
        }
        List<Job_Sequence_Run__c> runs = [SELECT Id, Status__c, StartedAt__c FROM Job_Sequence_Run__c WHERE Id = :runId WITH SYSTEM_MODE FOR UPDATE];
        if (runs.isEmpty() || runs[0].Status__c != STATUS_RUNNING) {
            return;
        }
        Datetime now = Datetime.now();
        runs[0].Status__c = status;
        runs[0].FinishedAt__c = now;
        runs[0].DurationSeconds__c = secondsBetween(runs[0].StartedAt__c, now);
        runs[0].Detail__c = detail?.left(DETAIL_LENGTH);
        update as system runs;
        System.debug('JobSequenceRunService()::finishRun:  run: ' + runs[0]);
    }

    /**
     * @description Finds the frequency's run that is still going. Runs older than the Run Timeout are marked
     * Abandoned instead, so a sequence that stopped without finishing cannot block its frequency forever.
     *
     * @param frequency The frequency
     * @param now       The current time
     *
     * @return The run still going, or null
     */
    private static Job_Sequence_Run__c findRunningRun(String frequency, Datetime now) {
        Integer timeout = getTimeoutMinutes();
        Datetime cutoff = now.addMinutes(-timeout);
        Job_Sequence_Run__c stillRunning;
        List<Job_Sequence_Run__c> abandoned = new List<Job_Sequence_Run__c>();
        for (Job_Sequence_Run__c run : [
                SELECT Id, Name, StartedAt__c, TimesSkipped__c
                FROM Job_Sequence_Run__c
                WHERE Frequency__c = :frequency AND Status__c = :STATUS_RUNNING
                WITH SYSTEM_MODE
                FOR UPDATE
        ]) {
            if (run.StartedAt__c == null || run.StartedAt__c < cutoff) {
                run.Status__c = STATUS_ABANDONED;
                run.FinishedAt__c = now;
                run.DurationSeconds__c = secondsBetween(run.StartedAt__c, now);
                run.Detail__c = ('Still running after ' + timeout + ' minutes, so it was treated as stopped.').left(DETAIL_LENGTH);
                abandoned.add(run);
            } else if (stillRunning == null) {
                stillRunning = run;
            }
        }
        if (!abandoned.isEmpty()) {
            update as system abandoned;
        }
        return stillRunning;
    }

    /**
     * @description Reads the Run Timeout setting, falling back to 60 minutes when it is blank or invalid.
     *
     * @return The timeout in minutes
     */
    @TestVisible
    private static Integer getTimeoutMinutes() {
        Decimal timeout = JobSequenceSettingsController.getSettings().RunTimeoutMinutes__c;
        return timeout == null || timeout < 1 ? DEFAULT_TIMEOUT_MINUTES : timeout.intValue();
    }

    /**
     * @description Whole seconds between two times.
     *
     * @param startTime The start, or null
     * @param endTime   The end
     *
     * @return The seconds, or null when the start is unknown
     */
    private static Decimal secondsBetween(Datetime startTime, Datetime endTime) {
        return startTime == null ? null : Math.max(0, (endTime.getTime() - startTime.getTime()) / 1000);
    }

    /**
     * @description Treats a blank number as zero.
     *
     * @param value The value
     *
     * @return The value, or 0
     */
    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
