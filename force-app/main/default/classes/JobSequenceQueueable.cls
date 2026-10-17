/**
 * Copyright 2019 Jason Hardy
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
 * @description: **JobSequenceQueueable** -- This class is responsible for handling queuing up new job sequences as well as running any sequence jobs that are
 * set to run in a non batch context.
 * @author: Jason Hardy
 * @date: 10/26/2019
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/26/2019 |  Jason Hardy      | Initial Creation (original author)                      |
 *   |  10/16/2026 |  Gary Butler      | Fork: Select/Where/Params LongTextArea for complex SOQL |
 *   |  10/16/2026 |  Gary Butler      | Added ApexDoc comments                                  |
 *   |  10/16/2026 |  Gary Butler      | API 68.0; explicit system mode on SOQL/DML              |
 *   |  10/16/2026 |  Gary Butler      | Carry run Id; finish the Job Sequence Run at chain end  |
 *   |  10/16/2026 |  Gary Butler      | Record run steps for queueable jobs and failures        |
 *   |  10/17/2026 |  Gary Butler      | Set jobId so queueable error emails are sent; debug     |
 *   |  10/17/2026 |  Gary Butler      | Standalone runs of one named job                        |
 *
 */
global with sharing class JobSequenceQueueable implements Queueable, Database.AllowsCallouts {
    global JobSequence js {Get;Set;}

    /**
     * @description Runs the current sequence job: starts a batch (or schedules a retry when too many batches
     * are running), or executes it inline and enqueues the next job. Errors are logged and emailed.
     * @param context The queueable context
     */
    global void execute(QueueableContext context) {
        if (js != null && js.sj != null && js.sjcs.Enabled__c) {
            try {
                if (js.stepStartedAt == null) js.stepStartedAt = Datetime.now();
                //Errors are logged against this job Id and finishJobSequence emails them
                if (context != null) js.jobId = context.getJobId();
                Boolean canProcessBatch = (js.isBatchJob && [SELECT count() FROM AsyncApexJob WHERE JobType='BatchApex' AND (Status = 'Processing' OR Status = 'Preparing') WITH SYSTEM_MODE] < 5);

                if (canProcessBatch && js.isBatchJob) Database.executeBatch(new JobSequenceBatch(js),js.batchSize);
                if (!canProcessBatch && js.isBatchJob) new JobSequence().scheduleRetry(js);
                if (!js.isBatchJob) {
                    JobSequenceExe.executeQueueable(js);
                    JobSequenceRunService.recordStep(js, 'Queueable', null, null, false);
                    //Setting up the next run after the queueable job has finished running
                    //Batch jobs will automatically kick off this same function in their finish context
                    if (js.standalone) {
                        JobSequenceRunService.finishRun(js.runId, JobSequenceRunService.STATUS_COMPLETED, null);
                    } else if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                        System.enqueueJob(new JobSequenceQueueable(js));
                    }
                }
            } catch(Exception e) {
                System.debug(LoggingLevel.ERROR, 'JobSequenceQueueable()::execute:  e: ' + e);
                js.logError(context.getJobId(), e, null);
                if (js != null && js.jobId != null) js.sendErrorEmail(js.jobId, [SELECT Id FROM Job_Sequence_Error__c WHERE BatchJobId__c = :js.jobId WITH SYSTEM_MODE]);
                //The sequence stops here, so the run it belongs to is over
                JobSequenceRunService.recordStep(js, js.isBatchJob ? 'Batch' : 'Queueable', null, null, true);
                JobSequenceRunService.finishRun(js.runId, JobSequenceRunService.STATUS_FAILED, e.getMessage());
            }
        } else if (js != null && js.sj != null) {
            JobSequenceRunService.finishRun(js.runId, JobSequenceRunService.STATUS_DISABLED, 'Stopped because the job sequencer was turned off.');
        }
    }

    /**
     * @description Constructs a job sequence queueable object based on the frequency that the jobs should be run on. This function
     * will query all of the sequence jobs with the matching frequency and work through all of them. This function
     * can be helpful when you wish to test the sequence jobs without scheduling a run. Example code to run anonymous
     * that will run all of the "Hourly" sequence jobs:
     *
     * System.enqueueJob(new JobSequenceQueueable('Hourly'));
     *
     * @param frequency The frequency of the sequence jobs that you wish to be run
     */
    global JobSequenceQueueable(String frequency) {
        this.js = getNextJob(frequency,null);
    }

    /**
     * @description Runs one active sequence job on its own: the sequence stops after it, so no other job in its
     * frequency runs. Example code to run anonymously:
     *
     * System.enqueueJob(new JobSequenceQueueable('One Time', 'MY_JOB'));
     *
     * @param frequency     The job's frequency
     * @param developerName The job's API name
     *
     * @throws JobSequenceException when the frequency is Test Only, or no active job by that name has the frequency
     */
    global JobSequenceQueueable(String frequency, String developerName) {
        this.js = getStandaloneJob(frequency, developerName);
    }

    /**
     * @description Runs one active sequence job on its own as part of a tracked Job Sequence Run.
     *
     * @param frequency     The job's frequency
     * @param developerName The job's API name
     * @param runId         The Job Sequence Run the job belongs to
     *
     * @throws JobSequenceException when the frequency is Test Only, or no active job by that name has the frequency
     */
    public JobSequenceQueueable(String frequency, String developerName, Id runId) {
        this.js = getStandaloneJob(frequency, developerName);
        this.js.runId = runId;
    }

    /**
     * @description Loads one active sequence job and marks it standalone.
     *
     * @param frequency     The job's frequency
     * @param developerName The job's API name
     *
     * @return The job sequence
     *
     * @throws JobSequenceException when the frequency is Test Only, or no active job by that name has the frequency
     */
    private JobSequence getStandaloneJob(String frequency, String developerName) {
        if (String.isBlank(frequency) || frequency.equalsIgnoreCase('Test Only')) {
            throw new JobSequenceException('Test Only jobs run only in Apex tests and cannot be run on their own.');
        }
        for (Sequence_Job__mdt sj : (List<Sequence_Job__mdt>) Database.query(constructSequenceJobQuery(frequency), AccessLevel.SYSTEM_MODE)) {
            if (sj.DeveloperName == developerName) {
                JobSequence standaloneJob = new JobSequence(sj);
                standaloneJob.standalone = true;
                return standaloneJob;
            }
        }
        throw new JobSequenceException('No active ' + frequency + ' sequence job named ' + developerName + ' was found.');
    }


    /**
     * @description Constructs a job sequence queueable for a run started by JobSequenceRunService. The run Id is
     * carried through the sequence so the run can be marked finished when its last job completes.
     *
     * @param frequency The frequency of the sequence jobs to run
     * @param runId     The Job Sequence Run that tracks this run
     */
    public JobSequenceQueueable(String frequency, Id runId) {
        this.js = getNextJob(frequency,null);
        if (this.js != null) this.js.runId = runId;
        if (this.js == null) JobSequenceRunService.finishRun(runId, JobSequenceRunService.STATUS_COMPLETED, 'No active sequence jobs were found.');
    }

    /**
     * @description Constructs a job schedule queueable object based on the job sequence
     *
     * @param js    The current job sequence. Used to determine what the next sequence will be
     */
    global JobSequenceQueueable(JobSequence js) {
        this.js = getNextJob(js.jobFrequency,js);
        //No next job means the sequence is done
        if (this.js == null) JobSequenceRunService.finishRun(js.runId, JobSequenceRunService.STATUS_COMPLETED, null);
    }

    /**
     * @description Constructs a job schedule queueable object based on the job sequence and whether or not it's a retry
     *
     * @param js        The current job sequence. Used to determine what the next sequence will be
     * @param isRetry   Indicates if this is a retry attempt (e.g. there were not enough available batch jobs when last run so a retry is needed)
     */
    global JobSequenceQueueable(JobSequence js, Boolean isRetry) {
        if (isRetry == null || !isRetry) this.js = getNextJob(js.jobFrequency,js);
        if (isRetry) this.js = js;
        if (this.js == null) JobSequenceRunService.finishRun(js.runId, JobSequenceRunService.STATUS_COMPLETED, null);
    }

    /**
     * @description This method will return the next job in the Sequence Job object.
     * If it is the first run, it will return the first record found
     * The first run is determined by the js parameter being null
     *
     * @param frequency The run frequency, this will be used to determine which sequences should be pulled
     * @param js        The current job sequence. Used to determine what the next sequence will be
     *
     * @return          The next job sequence that needs to be run
     */
    private JobSequence getNextJob(String frequency, JobSequence js) {
        JobSequence returnRecord;
        try {
            List<Sequence_Job__mdt> seqJobs = getSequenceJobs(frequency,js);
            //Going through each of the sequence job's to try to find the next one in line
            for (Integer i=0; i < seqJobs.size(); i++) {
                Sequence_Job__mdt sj = seqJobs[i];
                //If the job sequence is null, then we'll grab the first one we find
                returnRecord = js == null ? new JobSequence(sj) : returnRecord;
                Boolean hasNext = returnRecord == null && ((i+1) < (seqJobs.size()));
                //If the job sequence is defined, then we will check if there's another job after current iteration
                if (hasNext && js != null && js.sj != null) returnRecord = sj.Id == js.sj.Id ? new JobSequence(seqJobs[i+1]) : returnRecord;

                if (returnRecord != null) break;
            }
            //The next job belongs to the same run as the current one
            if (returnRecord != null && js != null) returnRecord.runId = js.runId;
        } catch (Exception e) {
            JobSequenceUtilities.logError(js == null ? null : js.jobId, js == null ? null : js.currentJob, js == null ? null : js.jobFrequency, e, null);
        }

        return returnRecord;
    }

    /**
     * @description Method will query the sequence job metadata table and return the records for the indicated frequency
     *
     * @param frequency The run frequency, this will be used to determine which sequences should be pulled
     * @param js        The current job sequence. Used to determine what the next sequence will be.
     *
     * @return The list of sequence job metadata records
     *
     * @throws JobSequenceException when no frequency can be determined or no active sequence jobs exist for it
     */
    private List<Sequence_Job__mdt> getSequenceJobs(String frequency, JobSequence js) {
        List<Sequence_Job__mdt> returnList;
        frequency = String.isBlank(frequency) && js != null ? js.jobFrequency : frequency;
        if (String.isBlank(frequency)) throw new JobSequenceException(Label.Job_Sequence_JobSequenceQueueable_Initialization_Error);

        returnList = Database.query(constructSequenceJobQuery(frequency), AccessLevel.SYSTEM_MODE);
        if (returnList.isEmpty() && !frequency.equalsIgnoreCase('notapplicable')) throw new JobSequenceException('No active Sequence Jobs were found for '+frequency+' frequency');
        return returnList;
    }

    /**
     * @description Constructs the sequence job query based on the frequency passed
     *
     * @param frequency The run frequency, this will be used to determine which sequences should be pulled
     *
     * @return          The query string
     */
    @TestVisible static String constructSequenceJobQuery(String frequency) {
        String query = String.format('SELECT {0} FROM {1} WHERE {2} ORDER BY {3}',new List<String>{
                String.join(new List<String>(Sequence_Job__mdt.SObjectType.getDescribe().fields.getMap().keySet()),','),
                'Sequence_Job__mdt',
                'Active__c = true AND Frequency__c = \''+frequency+'\'',
                'Order__c ASC'
        });

        return query;
    }
}