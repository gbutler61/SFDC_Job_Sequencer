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
 * @description: **JobSequenceTests** -- Unit tests covering the job sequencer classes, using the Test Only sequence job records.
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
 *
 */
@IsTest
public with sharing class JobSequenceTests {
    /**
     * @description Test setup: touches the running user so the test context has a committed user record.
     */
    @TestSetup static void createData() {
        User thisUser = [SELECT Id FROM User WHERE Id =:UserInfo.getUserId() WITH SYSTEM_MODE];
        System.runAs(thisUser) {
            update as system thisUser;
        }
    }

    /**
     * @description Verifies retries are scheduled and that exceeding max retries and missing parameters throw errors.
     */
    @IsTest static void JobSequenceClassRetryTest() {
        Test.startTest();
        JobSequence js = new JobSequence();
        List<Job_Sequence_Error__c> jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(jse.isEmpty(),'Errors already present!');
        String frequency = 'Test Only';
        List<Sequence_Job__mdt> sjs = Database.query(JobSequenceQueueable.constructSequenceJobQuery(frequency), AccessLevel.SYSTEM_MODE);
        js = new JobSequence(sjs[0]);
        js.scheduleRetry(js);
        js.numRetries = Integer.valueOf(js.sjcs.MaxRetries__c)+1;
        Boolean errorThrown = false;
        try {
            js.scheduleRetry(js);
        } catch(Exception e) {
            errorThrown = true;
        }
        System.assert(errorThrown,'An error was not thrown when max retries were hit');
        errorThrown = false;
        try {
            js.noParametersFoundError();
        } catch(Exception e) {
            errorThrown = true;
        }
        System.assert(errorThrown,'An error was not thrown when max retries were hit');
        Test.stopTest();
    }

    /**
     * @description Verifies a batch run with an unknown function logs a Job Sequence Error.
     */
    @IsTest static void JobSequenceBatchInvalidFunctionTest() {
        Test.startTest();
        List<Job_Sequence_Error__c> jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(jse.isEmpty(),'Errors already present!');
        JobSequence js = new JobSequence();
        String frequency = 'Test Only';
        List<Sequence_Job__mdt> sjs = Database.query(JobSequenceQueueable.constructSequenceJobQuery(frequency), AccessLevel.SYSTEM_MODE);
        js = new JobSequence(sjs[0]);
        js.executionJob = 'thisIsNotAValidFunction';
        js.query = 'SELECT Id FROM User LIMIT 1';
        js.isBatchJob = true;
        JobSequenceBatch jsb = new JobSequenceBatch(js);
        Database.executeBatch(jsb,200);
        Test.stopTest();
        jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(!jse.isEmpty(),'Errors were not created!');
    }

    /**
     * @description Verifies an invalid handler class name logs Job Sequence Errors.
     */
    @IsTest static void JobSequenceExeBadHandlerTest() {
        Job_Sequence_Error__c jse = new Job_Sequence_Error__c(JobFrequency__c='Test Only',BatchJobId__c='Test',Exception__c='Testing');
        insert as system jse;
        Test.startTest();
        JobSequence js = constructTestJobSequenceErrorJobSequenceObj();
        js.handlerName = 'JobSequenceTests';
        JobSequenceExe.executeQueueable(js);

        Test.stopTest();
        List<Job_Sequence_Error__c> jses = [SELECT Id FROM Job_Sequence_Error__c WHERE Id <> :jse.Id WITH SYSTEM_MODE];
        js.sendErrorEmail(null,jses);
        System.assert(!jses.isEmpty(),'Errors were not created for a bad handler name!');
    }

    /**
     * @description Verifies the DELETE DML job removes the matching records.
     */
    @IsTest static void JobSequenceExeDeleteTest() {
        Job_Sequence_Error__c jse = new Job_Sequence_Error__c(JobFrequency__c='Test Only',BatchJobId__c='Test',Exception__c='Testing');
        insert as system jse;
        Test.startTest();
        JobSequence js = constructTestJobSequenceErrorJobSequenceObj();
        JobSequenceExe.executeQueueable(js);

        Test.stopTest();
        List<Job_Sequence_Error__c> jses = [SELECT Id FROM Job_Sequence_Error__c WHERE Id =:jse.Id WITH SYSTEM_MODE];
        System.assert(jses.isEmpty(),'The errors were not deleted');
    }

    /**
     * @description Verifies the UPSERT DML job runs without logging errors.
     */
    @IsTest static void JobSequenceExeUpsertTests() {
        Job_Sequence_Error__c jse = new Job_Sequence_Error__c(JobFrequency__c='Test Only',BatchJobId__c='Test',Exception__c='Testing');
        insert as system jse;
        Test.startTest();
        JobSequence js = constructTestJobSequenceErrorJobSequenceObj();
        js.executionJob = 'UPSERT';
        JobSequenceExe.executeQueueable(js);

        Test.stopTest();
        List<Job_Sequence_Error__c> jses = [SELECT Id FROM Job_Sequence_Error__c WHERE Id <> :jse.Id WITH SYSTEM_MODE];
        System.assert(jses.isEmpty(),'New error records were created!');
    }

    /**
     * @description Verifies a queueable run with an unknown function logs a Job Sequence Error.
     */
    @IsTest static void JobSequenceQueueableInvalidFunctionTest() {
        Test.startTest();
        List<Job_Sequence_Error__c> jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(jse.isEmpty(),'Errors already present!');
        JobSequence js = new JobSequence();
        String frequency = 'Test Only';
        List<Sequence_Job__mdt> sjs = Database.query(JobSequenceQueueable.constructSequenceJobQuery(frequency), AccessLevel.SYSTEM_MODE);
        sjs[0].ExecutionJob__c = 'thisIsNotAValidFunction';
        sjs[0].IsBatchJob__c = false;
        js = new JobSequence(sjs[0]);
        System.enqueueJob(new JobSequenceQueueable(js,true));
        Test.stopTest();
        jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(!jse.isEmpty(),'Errors were not created!');
    }

    /**
     * @description Verifies the Test Only field-shift sequence updates records with the configured parameters.
     */
    @IsTest static void JobSequenceQueueableTests() {
        Test.startTest();
        System.enqueueJob(new JobSequenceQueueable('Test Only'));
        Test.stopTest();
        List<Sequence_Job__mdt> testOnlySequences = Database.query(JobSequenceQueueable.constructSequenceJobQuery('Test Only'), AccessLevel.SYSTEM_MODE);
        Sequence_Job__mdt mainTest;
        for (Sequence_Job__mdt sj : testOnlySequences) {
            if (sj.DeveloperName == 'TEST_FIELDSHIFT_FUNCTION') mainTest = sj;
        }
        Map<String,String> params = new Map<String,String>();
        for (String param : mainTest.Parameters__c.split(',')) {
            List<String> paramList = param.split(':');
            params.put(paramList[0],paramList[1]);
        }
        Boolean testsPassed = false;
        Set<String> paramsFound = new Set<String>();
        JobSequence js = new JobSequence(mainTest);
        for (User u : (List<User>) Database.query(js.query, AccessLevel.SYSTEM_MODE)) {
            for (String param : params.keySet()) {
                String fldVal = u.getPopulatedFieldsAsMap().containsKey(param) ? String.valueOf(u.get(param)) : '';
                if (param.containsIgnoreCase('Test.IsRunningTest')) paramsFound.add(param);
                if (!paramsFound.contains(param)) {
                    if (fldVal == params.get(param)) {
                        paramsFound.add(param);
                    }
                }
            }
            if (paramsFound.size() == params.size()) {
                testsPassed = true;
                break;
            }
        }
        System.assert(testsPassed,'The test did not pass!');
    }

    /**
     * @description Verifies the schedulable runs, exposes its error messages, and logs an error past max retries.
     */
    @IsTest static void JobSequenceSchedulableTests() {
        Test.startTest();
        List<Job_Sequence_Error__c> jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(jse.isEmpty(),'Errors already present!');
        String frequency = 'Test Only';
        List<Sequence_Job__mdt> sjs = Database.query(JobSequenceQueueable.constructSequenceJobQuery(frequency), AccessLevel.SYSTEM_MODE);
        JobSequence js = new JobSequence(sjs[0]);
        JobSequenceSchedulable jss = new JobSequenceSchedulable(js);
        jss.execute(null);
        JobSequenceSchedulable.getJobSequenceErrorMessage();
        JobSequenceSchedulable.getQueueableNullError();
        js.numRetries = Integer.valueOf(js.sjcs.MaxRetries__c)+1;
        jss = new JobSequenceSchedulable(js,true);
        System.schedule('testSchedule', '0 0 * * * ?', jss);
        Test.stopTest();
        jse = [SELECT Id FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        System.assert(!jse.isEmpty(),'Errors were not created!');
    }

    /**
     * @description Verifies the hourly schedulable enqueues without error.
     */
    @IsTest static void JobSequenceHourlyTests() {
        Test.startTest();
        new JobSequenceHourly().execute(null);
        Test.stopTest();
    }

    /**
     * @description Verifies the daily schedulable enqueues without error.
     */
    @IsTest static void JobSequenceDailyTests() {
        Test.startTest();
        new JobSequenceDaily().execute(null);
        Test.stopTest();
    }

    /**
     * @description Verifies the weekly schedulable enqueues without error.
     */
    @IsTest static void JobSequenceWeeklyTests() {
        Test.startTest();
        new JobSequenceWeekly().execute(null);
        Test.stopTest();
    }

    /**
     * @description Verifies the monthly schedulable enqueues without error.
     */
    @IsTest static void JobSequenceMonthlyTests() {
        Test.startTest();
        new JobSequenceMonthly().execute(null);
        Test.stopTest();
    }

    /**
     * @description Verifies the yearly schedulable enqueues without error.
     */
    @IsTest static void JobSequenceYearlyTests() {
        Test.startTest();
        new JobSequenceYearly().execute(null);
        Test.stopTest();
    }

    /**
     * @description Verifies scheduling all runs completes without error.
     */
    @IsTest static void JobSequenceUtilitiesScheduleAll() {
        Test.startTest();
        JobSequenceUtilities.scheduleAllRuns();
        Test.stopTest();
    }

    /**
     * @description Verifies parameter values are cast and applied to currency, date, boolean and text fields.
     */
    @IsTest static void JobSequenceUtilitiesChangeSobjectValueFromParameters() {
        Test.startTest();
        Opportunity opp = new Opportunity();
        Opportunity adjustedOpp = (Opportunity) JobSequenceUtilities.changeSobjectValueFromParameters(
                opp,
                opp.getSObjectType().getDescribe().fields.getMap(),
                new Map<String,String>{
                        'Amount'=>'100',
                        'CloseDate'=>String.valueOf(Date.today()),
                        'IsPrivate'=>'true',
                        'Name'=>'test'
                }
        );
        System.assertEquals(adjustedOpp.Amount,100,'The amount was not set!');
        System.assertEquals(adjustedOpp.CloseDate.format(),Date.today().format(),'The Close Date was not set!');
        System.assertEquals(adjustedOpp.Name,'test','The name was not set!');
        System.assert(adjustedOpp.IsPrivate,'Is Private was not set!');

        Test.stopTest();
    }

    /**
     * @description Verifies the controller page references and that each schedule method schedules its job.
     */
    @IsTest static void JobSequenceVisualforceContTests() {
        Test.startTest();
        JobSequenceVisualforceCont jsvc = new JobSequenceVisualforceCont();
        System.assert(jsvc.getPageRefForSequenceJobs() != null, 'The page reference was returned as null');
        System.assert(jsvc.getPageRefForSequenceJobCustomSettingSetup() != null, 'The page reference was returned as null');
        jsvc.scheduleHourlyRun();
        jsvc.scheduleDailyRun();
        jsvc.scheduleWeeklyRun();
        jsvc.scheduleMonthlyRun();
        jsvc.scheduleQuarterlyRun();
        jsvc.scheduleYearlyRun();
        System.assertEquals(6,[SELECT Id FROM AsyncApexJob WITH SYSTEM_MODE].size(),'The correct number of jobs were not scheduled');
        jsvc.scheduleAllRuns();

        Test.stopTest();
    }

    /**
     * @description Verifies the controller schedules all six runs.
     */
    @IsTest static void JobSequenceVisualforceContSchAllTests() {
        Test.startTest();
        JobSequenceVisualforceCont jsvc = new JobSequenceVisualforceCont();
        jsvc.scheduleAllRuns();
        System.assertEquals(6,[SELECT Id FROM AsyncApexJob WITH SYSTEM_MODE].size(),'The correct number of jobs were not scheduled');
        Test.stopTest();
    }

    /**
     * @description Builds a DML job sequence that deletes the test Job Sequence Error records.
     * @return The configured job sequence
     */
    private static JobSequence constructTestJobSequenceErrorJobSequenceObj() {
        JobSequence js = new JobSequence();
        js.allOrNone = true;
        js.batchSize = 200;
        js.currentJob = 'Test';
        js.executionJob = 'DELETE';
        js.jobFrequency = 'Test Only';
        js.jobType = 'DML';
        js.paramStringsByStrings = null;
        js.query = 'SELECT Id FROM Job_Sequence_Error__c WHERE BatchJobId__c = \'Test\'';
        js.permDelete = true;
        js.upsertField = null;
        js.isBatchJob = false;
        js.handlerName = 'JobSequenceDefaultHandler';
        return js;
    }

}