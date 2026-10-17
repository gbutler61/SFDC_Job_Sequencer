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
 * @description: **JobSequence** -- This is the a wrapper class which is used by the various job sequence management class to exchange a job. Additionally,
 * contains various functions to manage aspects of a particular job sequence.
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
 *   |  10/16/2026 |  Gary Butler      | Add runId to track the Job Sequence Run                 |
 *   |  10/16/2026 |  Gary Butler      | Settings tokens; per-step run metrics                   |
 *   |  10/16/2026 |  Gary Butler      | Order By optional in the built query                    |
 *   |  10/17/2026 |  Gary Butler      | Fix parameter parsing and the {0} test swap             |
 *   |  10/17/2026 |  Gary Butler      | Test Query: test-parameter override, queryTemplate      |
 *   |  10/17/2026 |  Gary Butler      | Typed variables (JSON params) replace DateTimeVar/{0}   |
 *   |  10/17/2026 |  Gary Butler      | Standalone flag: the sequence stops after this job      |
 *
 */
global without sharing class JobSequence {
    global Boolean allOrNone {
        get {
            if (this.allOrNone == null) this.allOrNone = true;
            return this.allOrNone;
        }
        set;
    }
    global Boolean isBatchJob {
        get {
            if (this.isBatchJob == null) this.isBatchJob = false;
            return this.isBatchJob;
        }
        set;
    }
    global Boolean permDelete {
        get {
            if (this.permDelete == null) this.permDelete = false;
            return this.permDelete;
        }
        set;
    }
    global Id jobId {get;set;}
    //The Job Sequence Run this job belongs to; null when the sequence was started outside JobSequenceRunService
    public Id runId {get;set;}
    //True when only this job runs: the sequence stops after it instead of moving on to the next job in its frequency
    public Boolean standalone {
        get {
            if (this.standalone == null) this.standalone = false;
            return this.standalone;
        }
        set;
    }
    //Lets Test Query build a query with the test values outside a test; null means use Test.isRunningTest()
    public static Boolean useTestParameters;
    //The query as built from the record, with its {!...} tokens still in it
    public String queryTemplate {get;set;}
    //The Job Parameters: field values, variables and handler parameters
    public JobSequenceVariables.Definition jobParameters {get;set;}
    //The values FieldShift sets, by lower-case field API name; 'null' clears the field
    global Map<String,String> fieldValuesByField {get;set;}
    //Metrics for the current sequence job (one step of its run); each step gets a new JobSequence, so they start at 0
    public Datetime stepStartedAt {get;set;}
    public Integer recordsProcessed {
        get {
            if (this.recordsProcessed == null) this.recordsProcessed = 0;
            return this.recordsProcessed;
        }
        set;
    }
    public Integer recordsFailed {
        get {
            if (this.recordsFailed == null) this.recordsFailed = 0;
            return this.recordsFailed;
        }
        set;
    }
    public Integer errorsLogged {
        get {
            if (this.errorsLogged == null) this.errorsLogged = 0;
            return this.errorsLogged;
        }
        set;
    }

    global String currentJob {get;set;}
    global String executionJob {get;set;}
    global String handlerName { //The name of the handler class that will be run. If none, we'll use the default
        get {
            if (this.handlerName == null) this.handlerName = 'JobSequenceDefaultHandler';
            return this.handlerName;
        }
        set;
    }
    global String jobFrequency {get;set;}
    global String jobType {get;set;}
    public String query {get;set;}
    global String upsertField {get;set;}

    global Integer batchSize {
        get {
            if (this.batchSize == null) this.batchSize = 200;
            return this.batchSize;
        }
        set;
    }
    global Integer numRetries {
        get {
            if (this.numRetries == null) this.numRetries = 0;
            return this.numRetries;
        }
        set;
    }

    global Map<String,String> paramStringsByStrings {get;set;}

    global Sequence_Job__mdt sj {get;set;} //The current sequence job record

    global Sequence_Jobs_Settings__c sjcs { //The sequence job settings, used to check the state of the custom setting
        get {
            this.sjcs = this.sjcs == null ? Sequence_Jobs_Settings__c.getInstance() : this.sjcs;
            //If there isn't a sequence job custom setting active in the org, one will be created here. Particularly
            //useful for when unit tests are running, this gives us the chance to get the default settings from the CS
            if (sjcs == null || sjcs.Name == null) {
                this.sjcs = (Sequence_Jobs_Settings__c) Sequence_Jobs_Settings__c.SObjectType.newSObject(null, true);
                this.sjcs.Name = 'default';
                //Not actually upserting here during testing because it can be problematic when running parallel tests
                if (!Test.isRunningTest()) upsert as system this.sjcs;
            }
            return sjcs;
        }
        set;
    }

    /**
     * @description Default constructor; properties are populated by the caller.
     */
    global JobSequence(){}

    /**
     * @description Job sequence constructor using a sequence job record
     *
     * @param sj    The sequence job record to initialize with
     */
    global JobSequence(Sequence_Job__mdt sj) {
        this.allOrNone = sj.AllOrNone__c;
        this.batchSize = Integer.valueOf(sj.BatchLimit__c);
        this.currentJob = sj.DeveloperName;
        this.executionJob = sj.ExecutionJob__c;
        this.jobFrequency = sj.Frequency__c;
        this.jobType = sj.Type__c;
        this.jobParameters = JobSequenceVariables.parse(sj.Parameters__c);
        JobSequenceVariables.Resolver resolver = new JobSequenceVariables.Resolver(
                this.jobParameters, useTestParameters != null ? useTestParameters : Test.isRunningTest());
        this.queryTemplate = constructQuery(sj);
        this.query = resolver.resolveQuery(this.queryTemplate);
        this.fieldValuesByField = new Map<String,String>();
        for (JobSequenceVariables.FieldValue fv : this.jobParameters.fieldValues) {
            if (String.isNotBlank(fv.field)) {
                this.fieldValuesByField.put(fv.field.trim().toLowerCase(), fv.blank == true ? 'null' : resolver.resolveValue(fv.value));
            }
        }
        //Handler parameters keep their original shape: lower-case names, null when there are none
        for (String name : this.jobParameters.handlerParameters.keySet()) {
            if (this.paramStringsByStrings == null) this.paramStringsByStrings = new Map<String,String>();
            this.paramStringsByStrings.put(name.trim().toLowerCase(), resolver.resolveValue(this.jobParameters.handlerParameters.get(name)));
        }
        this.sj = sj;
        this.permDelete = sj.PermDelete__c;
        this.upsertField = sj.UpsertExtIdField__c;
        this.isBatchJob = sj.IsBatchJob__c;
        this.handlerName = sj.HandlerClass__c;
    }

    /**
     * @description Method will log an error in the Job Sequence error object
     *
     * @param jobId     The job Id to log against
     * @param e         The exception
     * @param idScope   The ids that failed
     */
    global void logError(Id jobId, Exception e, Set<Id> idScope) {
        this.errorsLogged++;
        JobSequenceUtilities.logError(jobId, this.currentJob, this.jobFrequency, e, idScope, this.runId);
    }

    /**
     * @description Will throw a maximum retry limit reached error
     *
     * @throws JobSequenceException always, naming the job and the configured maximum retries
     */
    global void maxRetryLimitReachedError() {
        throw new JobSequenceException(
            String.format(
                    Label.Job_Sequence_Max_Retry_Error,
                    new List<String> {
                            String.valueOf(sjcs.MaxRetries__c),
                            this.sj.DeveloperName,
                            this.executionJob
                    }
            )
        );
    }

    /**
     * @description Will throw a no function found error
     *
     * @throws JobSequenceException always, naming the execution job that has no matching function
     */
    global void noFunctionFoundError() {
        String errorMsg = String.format(
            Label.Job_Sequence_No_Function_Found_Error,
            new List<String>{
                    this.executionJob
            }
        );
        throw new JobSequenceException(errorMsg);
    }

    /**
     * @description Will throw a no parameters found error
     *
     * @throws JobSequenceException always, naming the execution job and sequence job record
     */
    global void noParametersFoundError() {
        throw new JobSequenceException(
            String.format(
                Label.Job_Sequence_Parameters_Not_Found,
                new List<String> {
                        this.executionJob,
                        this.sj.Id
                }
            )
        );
    }

    /**
     * @description Function will schedule a future run for the current job sequence
     *
     * @param js    The current job sequence.
     *
     * @throws JobSequenceException when the job has already reached the maximum number of retries
     */
    global void scheduleRetry(JobSequence js) {
        if (js.numRetries >= this.sjcs.MaxRetries__c) js.maxRetryLimitReachedError();
        if (js.numRetries <= this.sjcs.MaxRetries__c) {
            js.numRetries++;
            Datetime futureRunTime = Datetime.now().addMinutes(Integer.valueOf(this.sjcs.MinutesUntilRetry__c));
            String timeForScheduler = futureRunTime.format('s m H d M \'?\' yyyy');
            System.schedule(js.currentJob+' Retry:'+timeForScheduler,timeForScheduler,new JobSequenceSchedulable(js,true));
        }
    }

    /**
     * @description This function will send error emails if applicable
     *
     * @param jobId     The job Id that will be used to identify the job that errored out
     * @param errors    The error message records
     */
    global void sendErrorEmail(Id jobId, List<Job_Sequence_Error__c> errors) {
        sendErrorEmail(jobId,this.currentJob, this.jobFrequency, errors);
    }

    /**
     * @description Function will structure a query based on the data found in the sequence job record
     *
     * @param sj    The Sequence Job object record
     *
     * @return      The constructed query
     */
    private String constructQuery(Sequence_Job__mdt sj) {
        //Order By is optional; without one the query has no ORDER BY clause
        String returnQuery = 'SELECT {0} FROM {1} WHERE {2}' + (String.isBlank(sj.OrderBy__c) ? '' : ' ORDER BY {3}');
        String limitStr = sj.Limit__c != null ? String.valueOf(sj.Limit__c) : null;
        limitStr = String.isNotBlank(limitStr) && limitStr.endsWith('.0') ? limitStr.left(limitStr.length()-2) : limitStr;
        returnQuery += String.isNotBlank(limitStr) ? ' LIMIT '+limitStr : '';
        //Tokens such as {!Var.name} and {!Settings.Field__c} are left in; JobSequenceVariables replaces them
        return returnQuery.replace('{0}', '' + sj.Select__c).replace('{1}', '' + sj.From__c)
                .replace('{2}', '' + sj.Where__c).replace('{3}', '' + sj.OrderBy__c);
    }

    /**
     * @description This function will send error emails if applicable
     *
     * @param jobId         The job Id that will be used to identify the job that errored out
     * @param currentJob    The name of the current job
     * @param jobFrequency  The frequency of the current job
     * @param errors        The error message records
     */
    private void sendErrorEmail(Id jobId, String currentJob, String jobFrequency, List<Job_Sequence_Error__c> errors) {
        if (errors != null && !errors.isEmpty()) {
            String notificationEmail = this.sj == null ? UserInfo.getUserEmail() : this.sj.NotificationEmail__c;
            List<String> emails = (this.sj == null || String.isBlank(this.sj.NotificationEmail__c)) ?
                    null : new List<String>{notificationEmail};
            JobSequenceUtilities.sendEmailNotification(
                    null,
                    emails,
                    null,
                    UserInfo.getUserId(),
                    String.format(Label.Job_Sequence_Error_Email_Subject,new List<String>{currentJob,jobFrequency}),
                    String.format(Label.Job_Sequence_Error_Email_Body,new List<String>{jobId}),
                    null,
                    'High'
            );

        }
    }
}
