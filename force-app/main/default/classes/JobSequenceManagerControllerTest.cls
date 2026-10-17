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
 * @description: **JobSequenceManagerControllerTest** -- Unit tests for JobSequenceManagerController and
 * JobSequenceDeployCallback: listing, validation, saving, activation, reordering, Test Query and deploy results.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/17/2026 |  Gary Butler      | Tests for handler options and picklist values           |
 *   |  10/17/2026 |  Gary Butler      | Tests for typed-variable parameters and FieldShift      |
 *   |  10/17/2026 |  Gary Butler      | Run standalone refuses non-One Time jobs                |
 *
 */
@IsTest
private class JobSequenceManagerControllerTest {

    /**
     * @description Records each deployment instead of running it, since tests cannot deploy metadata.
     */
    private class RecordingDeployer implements JobSequenceManagerController.Deployer {
        public List<Metadata.DeployContainer> containers = new List<Metadata.DeployContainer>();

        /**
         * @description Keeps the container and returns a fake deployment Id.
         *
         * @param container The records that would be deployed
         *
         * @return A fake deployment Id
         */
        public Id deploy(Metadata.DeployContainer container) {
            containers.add(container);
            return '0Af000000000001';
        }
    }

    /**
     * @description Builds an in-memory Sequence Job record; JSON is used because DeveloperName is not writeable.
     *
     * @param developerName The API name
     * @param frequency     The frequency
     * @param order         The run order
     *
     * @return The record
     */
    private static Sequence_Job__mdt record(String developerName, String frequency, String order) {
        Map<String, Object> fields = new Map<String, Object>{
                'DeveloperName' => developerName, 'MasterLabel' => developerName, 'Active__c' => true,
                'Frequency__c' => frequency, 'Order__c' => order, 'IsBatchJob__c' => false, 'Type__c' => 'Function',
                'HandlerClass__c' => 'JobSequenceDefaultHandler', 'ExecutionJob__c' => 'FieldShift',
                'AllOrNone__c' => false, 'PermDelete__c' => false
        };
        return (Sequence_Job__mdt) JSON.deserialize(JSON.serialize(fields), Sequence_Job__mdt.class);
    }

    /**
     * @description Builds a valid editor job.
     *
     * @return The job
     */
    private static JobSequenceManagerController.SequenceJob validJob() {
        JobSequenceManagerController.SequenceJob job = new JobSequenceManagerController.SequenceJob();
        job.developerName = 'NEW_DAILY_JOB';
        job.label = 'New daily job';
        job.active = true;
        job.frequency = 'Daily';
        job.order = 'D01';
        job.isBatchJob = true;
        job.jobType = 'DML';
        job.executionJob = 'UPDATE';
        job.handlerClass = 'JobSequenceDefaultHandler';
        job.selectFields = 'Id';
        job.fromObject = 'User';
        job.whereClause = 'IsActive = true';
        job.orderBy = 'CreatedDate';
        job.batchLimit = 100;
        return job;
    }

    /**
     * @description Returns the value deployed for a field.
     *
     * @param record The deployed record
     * @param field  The field API name
     *
     * @return The value
     */
    private static Object valueOf(Metadata.CustomMetadata record, String field) {
        for (Metadata.CustomMetadataValue value : record.values) {
            if (value.field == field) return value.value;
        }
        return null;
    }

    /**
     * @description Verifies the list and the picklist options load.
     */
    @IsTest
    static void listsJobsAndOptions() {
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>{record('JOB_A', 'Daily', 'D01')};

        Test.startTest();
        List<JobSequenceManagerController.SequenceJob> jobs = JobSequenceManagerController.getSequenceJobs();
        JobSequenceManagerController.FieldOptions options = JobSequenceManagerController.getFieldOptions();
        Test.stopTest();

        Assert.areEqual(1, jobs.size(), 'One job should be listed');
        Assert.areEqual('JOB_A', jobs[0].developerName, 'The job should be listed by API name');
        Assert.isTrue(options.frequencies.contains('Daily'), 'Daily should be a frequency option');
        Assert.isTrue(options.jobTypes.contains('DML'), 'DML should be a job type option');
    }

    /**
     * @description Verifies a valid new job is deployed with every field, including the long text fields.
     */
    @IsTest
    static void saveDeploysEveryField() {
        RecordingDeployer recorder = new RecordingDeployer();
        JobSequenceManagerController.deployer = recorder;
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>();
        JobSequenceManagerController.SequenceJob job = validJob();
        job.whereClause = 'IsActive = true AND (' + 'Name != null OR '.repeat(500) + 'Id != null)';

        Test.startTest();
        Id deploymentId = JobSequenceManagerController.saveSequenceJob(JSON.serialize(job), true);
        Test.stopTest();

        Assert.isNotNull(deploymentId, 'A deployment Id should be returned');
        Metadata.CustomMetadata deployed = (Metadata.CustomMetadata) recorder.containers[0].getMetadata()[0];
        Assert.areEqual('Sequence_Job.NEW_DAILY_JOB', deployed.fullName, 'The record should be named after the job');
        Assert.areEqual(18, deployed.values.size(), 'Every field should be deployed');
        Assert.areEqual(job.whereClause, valueOf(deployed, 'Where__c'), 'The long where clause should be deployed intact');
    }

    /**
     * @description Verifies the checks that mirror the Sequence Job validation rules.
     */
    @IsTest
    static void validateMirrorsValidationRules() {
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>{record('EXISTING_JOB', 'Daily', 'D01')};
        JobSequenceManagerController.SequenceJob job = validJob();
        job.developerName = 'EXISTING_JOB';
        job.executionJob = 'INSERT';
        job.batchLimit = 500;
        job.whereClause = 'WHERE IsActive = true';
        job.selectFields = null;
        job.upsertExtIdField = 'Id';
        job.handlerClass = 'NotARealHandlerClass';

        Test.startTest();
        List<String> problems = JobSequenceManagerController.validate(job, true);
        Boolean saveRejected = false;
        try {
            JobSequenceManagerController.saveSequenceJob(JSON.serialize(job), true);
        } catch (AuraHandledException e) {
            saveRejected = e.getMessage().contains('UPDATE or DELETE');
        }
        Test.stopTest();

        String allProblems = String.join(problems, '\n');
        Assert.isTrue(allProblems.contains('already exists'), 'A duplicate name should be rejected');
        Assert.isTrue(allProblems.contains('UPDATE or DELETE'), 'INSERT should be rejected for a DML job');
        Assert.isTrue(allProblems.contains('1 to 200'), 'A batch limit over 200 should be rejected');
        Assert.isTrue(allProblems.contains('WHERE keyword'), 'A where clause starting with WHERE should be rejected');
        Assert.isTrue(allProblems.contains('Select, From and Where'), 'A batch job without a select should be rejected');
        Assert.isTrue(allProblems.contains('Upsert External Id'), 'Id as the upsert field should be rejected');
        Assert.isTrue(allProblems.contains('NotARealHandlerClass'), 'An unknown handler should be rejected');
        Assert.isTrue(saveRejected, 'An invalid job should not be saved');
    }

    /**
     * @description Verifies deactivating redeploys the job with Active off and its other values unchanged.
     */
    @IsTest
    static void setActiveRedeploysWholeRecord() {
        RecordingDeployer recorder = new RecordingDeployer();
        JobSequenceManagerController.deployer = recorder;
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>{record('JOB_A', 'Daily', 'D01')};

        Test.startTest();
        JobSequenceManagerController.setActive('JOB_A', false);
        Test.stopTest();

        Metadata.CustomMetadata deployed = (Metadata.CustomMetadata) recorder.containers[0].getMetadata()[0];
        Assert.areEqual(false, valueOf(deployed, 'Active__c'), 'The job should be deactivated');
        Assert.areEqual('D01', valueOf(deployed, 'Order__c'), 'The other values should be kept');
    }

    /**
     * @description Verifies moving a job swaps its Order with its neighbor's and rejects impossible moves.
     */
    @IsTest
    static void moveJobSwapsOrder() {
        RecordingDeployer recorder = new RecordingDeployer();
        JobSequenceManagerController.deployer = recorder;
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>{
                record('JOB_A', 'Daily', 'D01'), record('JOB_B', 'Daily', 'D02'), record('JOB_C', 'Hourly', 'H01')
        };

        Test.startTest();
        JobSequenceManagerController.moveJob('JOB_B', 'up');
        Boolean firstRejected = false;
        try {
            JobSequenceManagerController.moveJob('JOB_A', 'up');
        } catch (AuraHandledException e) {
            firstRejected = e.getMessage().contains('already first');
        }
        Boolean onlyJobRejected = false;
        try {
            JobSequenceManagerController.moveJob('JOB_C', 'down');
        } catch (AuraHandledException e) {
            onlyJobRejected = e.getMessage().contains('already last');
        }
        Test.stopTest();

        List<Metadata.Metadata> deployed = recorder.containers[0].getMetadata();
        Assert.areEqual(2, deployed.size(), 'Both jobs should be deployed together');
        Assert.areEqual('D01', valueOf((Metadata.CustomMetadata) deployed[0], 'Order__c'), 'JOB_B should take D01');
        Assert.areEqual('D02', valueOf((Metadata.CustomMetadata) deployed[1], 'Order__c'), 'JOB_A should take D02');
        Assert.isTrue(firstRejected, 'The first job cannot move up');
        Assert.isTrue(onlyJobRejected, 'The only job in a frequency cannot move down');
    }

    /**
     * @description Verifies moving is rejected when the two jobs share an Order value.
     */
    @IsTest
    static void moveJobRejectsDuplicateOrder() {
        JobSequenceManagerController.deployer = new RecordingDeployer();
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>{
                record('JOB_A', 'Daily', 'D01'), record('JOB_B', 'Daily', 'D01')
        };

        Boolean rejected = false;
        Test.startTest();
        try {
            JobSequenceManagerController.moveJob('JOB_B', 'up');
        } catch (AuraHandledException e) {
            rejected = e.getMessage().contains('different Order values');
        }
        Test.stopTest();

        Assert.isTrue(rejected, 'Jobs with the same Order cannot be swapped');
    }

    /**
     * @description Verifies Test Query builds and runs a valid query, reports an invalid one, and needs a From.
     */
    @IsTest
    static void testQueryReportsValidAndInvalidQueries() {
        JobSequenceManagerController.SequenceJob job = validJob();
        JobSequenceManagerController.SequenceJob badJob = validJob();
        badJob.whereClause = 'NotAField__c = 1';
        JobSequenceManagerController.SequenceJob noQueryJob = validJob();
        noQueryJob.fromObject = null;

        Test.startTest();
        JobSequenceManagerController.TestQueryResult good = JobSequenceManagerController.testQuery(JSON.serialize(job), false);
        JobSequenceManagerController.TestQueryResult bad = JobSequenceManagerController.testQuery(JSON.serialize(badJob), false);
        JobSequenceManagerController.TestQueryResult noQuery = JobSequenceManagerController.testQuery(JSON.serialize(noQueryJob), false);
        Test.stopTest();

        Assert.isTrue(good.isValid, 'The query should be valid: ' + good.errorMessage);
        Assert.isTrue(good.query.startsWith('SELECT Id FROM User WHERE IsActive = true'), 'The built query should be returned');
        Assert.isTrue(good.matchingRows >= 1, 'At least the running user should match');
        Assert.isFalse(bad.isValid, 'An unknown field should make the query invalid');
        Assert.isNotNull(bad.errorMessage, 'The query error should be returned');
        Assert.isFalse(noQuery.isValid, 'A job without From has no query to test');
    }

    /**
     * @description Verifies the query wizard lists objects and an object's fields, and rejects an unknown object.
     */
    @IsTest
    static void wizardListsObjectsAndFields() {
        Test.startTest();
        List<JobSequenceManagerController.SchemaOption> objects = JobSequenceManagerController.getObjectOptions();
        List<JobSequenceManagerController.SchemaOption> fields = JobSequenceManagerController.getObjectFields('Account');
        Boolean unknownRejected = false;
        try {
            JobSequenceManagerController.getObjectFields('No_Such_Object__c');
        } catch (AuraHandledException e) {
            unknownRejected = e.getMessage().contains('No_Such_Object__c');
        }
        Test.stopTest();

        Set<String> objectNames = new Set<String>();
        for (JobSequenceManagerController.SchemaOption option : objects) objectNames.add(option.value);
        Assert.isTrue(objectNames.contains('Account'), 'Account should be offered');
        Assert.isFalse(objectNames.contains('Job_Sequencer_Deploy_Result__e'), 'Platform events cannot be queried and should not be offered');
        Boolean hasName = false;
        for (JobSequenceManagerController.SchemaOption option : fields) hasName = hasName || option.value == 'Name';
        Assert.isTrue(hasName, 'Account Name should be offered');
        Boolean hasContacts = false;
        for (JobSequenceManagerController.SchemaOption option : fields) {
            hasContacts = hasContacts || (option.kind == 'child' && option.value == 'Contacts' && option.childObject == 'Contact');
        }
        Assert.isTrue(hasContacts, 'The Contacts related list should be offered');
        Assert.isTrue(unknownRejected, 'An unknown object should be rejected');
    }

    /**
     * @description Verifies the default handler is offered first with its FieldShift function, and picklist values are
     * returned for picklist fields.
     */
    @IsTest
    static void handlerAndFieldDetailsAreListed() {
        Test.startTest();
        List<JobSequenceManagerController.HandlerOption> handlers = JobSequenceManagerController.getHandlerOptions();
        List<JobSequenceManagerController.SchemaOption> fields = JobSequenceManagerController.getObjectFields('Opportunity');
        Test.stopTest();

        Assert.areEqual('JobSequenceDefaultHandler', handlers[0].className, 'The default handler should be first');
        Assert.isTrue(handlers[0].functions.contains('FieldShift'), 'The default handler should list FieldShift');
        Boolean stageHasValues = false;
        for (JobSequenceManagerController.SchemaOption option : fields) {
            if (option.value == 'StageName') stageHasValues = option.picklistValues != null && !option.picklistValues.isEmpty();
        }
        Assert.isTrue(stageHasValues, 'StageName should come with its picklist values');
    }

    /**
     * @description Verifies a query without Order By, but with a record limit, still tests correctly.
     */
    @IsTest
    static void testQueryWithoutOrderBy() {
        JobSequenceManagerController.SequenceJob job = validJob();
        job.orderBy = null;
        job.recordLimit = 10;
        JobSequenceManagerController.SequenceJob badRelationship = validJob();
        badRelationship.whereClause = 'NoSuchParent__r.Name = \'x\'';

        Test.startTest();
        JobSequenceManagerController.TestQueryResult result = JobSequenceManagerController.testQuery(JSON.serialize(job), false);
        JobSequenceManagerController.TestQueryResult bad = JobSequenceManagerController.testQuery(JSON.serialize(badRelationship), false);
        Test.stopTest();

        Assert.isTrue(result.isValid, 'The query should be valid: ' + result.errorMessage);
        Assert.isFalse(result.query.contains('ORDER BY'), 'A blank Order By should leave out ORDER BY');
        Assert.isTrue(result.query.endsWith('LIMIT 10'), 'The record limit should be kept');
        Assert.isFalse(bad.isValid, 'An unknown relationship should be invalid');
        Assert.isNotNull(bad.queryHint, 'An unknown relationship should get a hint about this org');
    }

    /**
     * @description Builds Job Parameters JSON with one variable.
     *
     * @param name      The variable name
     * @param type      The variable type
     * @param value     The value for scheduled runs
     * @param testValue The value when Test.isRunningTest() is true
     *
     * @return The JSON
     */
    private static String variableParameters(String name, String type, String value, String testValue) {
        return JSON.serialize(new Map<String, Object>{
            'version' => 1,
            'variables' => new List<Object>{
                new Map<String, Object>{'name' => name, 'type' => type, 'value' => value, 'testValue' => testValue}
            }
        });
    }

    /**
     * @description Verifies Test Query resolves {!Var.x} for scheduled runs and for Test.isRunningTest(), and shows
     * the query as written as well.
     */
    @IsTest
    static void testQueryResolvesVariables() {
        JobSequenceManagerController.SequenceJob job = validJob();
        job.whereClause = 'IsActive = true AND LastModifiedDate >= {!Var.since}';
        job.parameters = variableParameters('since', 'RelativeDateTime', '-1 days', '-1 minutes');

        Test.startTest();
        JobSequenceManagerController.TestQueryResult scheduled = JobSequenceManagerController.testQuery(JSON.serialize(job), false);
        JobSequenceManagerController.TestQueryResult asTest = JobSequenceManagerController.testQuery(JSON.serialize(job), true);
        Test.stopTest();

        Assert.isTrue(scheduled.isValid, 'The query should run: ' + scheduled.errorMessage);
        Assert.isTrue(scheduled.query.contains('LastModifiedDate >= 20'), 'The date/time should be filled in: ' + scheduled.query);
        Assert.isTrue(scheduled.queryWithVariables.contains('{!Var.since}'), 'The query as written should keep the token');
        Assert.isNull(scheduled.queryHint, 'A defined, used variable needs no hint: ' + scheduled.queryHint);
        Assert.isTrue(asTest.isValid, 'The test version should run: ' + asTest.errorMessage);
        Assert.areNotEqual(scheduled.query, asTest.query, 'Scheduled runs and tests use different values');
    }

    /**
     * @description Verifies the parameter checks: undefined and unused variables, a Test Only job with only a test
     * value, and parameters that are not JSON.
     */
    @IsTest
    static void parameterChecks() {
        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>();
        JobSequenceManagerController.SequenceJob undefinedJob = validJob();
        undefinedJob.whereClause = 'IsActive = true AND LastModifiedDate >= {!Var.since}';

        JobSequenceManagerController.SequenceJob unusedJob = validJob();
        unusedJob.parameters = variableParameters('since', 'RelativeDateTime', '-1 days', null);

        JobSequenceManagerController.SequenceJob testOnlyValue = validJob();
        testOnlyValue.whereClause = 'IsActive = true AND LastModifiedDate >= {!Var.since}';
        testOnlyValue.parameters = variableParameters('since', 'RelativeDateTime', null, '-1 minutes');

        JobSequenceManagerController.SequenceJob notJson = validJob();
        notJson.parameters = 'StageName:Closed Lost';
        JobSequenceManagerController.SequenceJob badJson = validJob();
        badJson.parameters = '{"variables": [';

        Test.startTest();
        String undefinedProblems = String.join(JobSequenceManagerController.validate(undefinedJob, true), ' ');
        String unusedProblems = String.join(JobSequenceManagerController.validate(unusedJob, true), ' ');
        String unusedHint = JobSequenceManagerController.getParameterHint(unusedJob);
        String dailyProblems = String.join(JobSequenceManagerController.validate(testOnlyValue, true), ' ');
        testOnlyValue.frequency = 'Test Only';
        String testOnlyProblems = String.join(JobSequenceManagerController.validate(testOnlyValue, true), ' ');
        String notJsonProblems = String.join(JobSequenceManagerController.validate(notJson, true), ' ');
        String badJsonProblems = String.join(JobSequenceManagerController.validate(badJson, true), ' ');
        Test.stopTest();

        Assert.isTrue(undefinedProblems.contains('no variable named since'), 'An undefined variable should be refused: ' + undefinedProblems);
        Assert.isFalse(unusedProblems.contains('since'), 'An unused variable should not block the save: ' + unusedProblems);
        Assert.isTrue(unusedHint.contains('never used'), 'An unused variable should be pointed out: ' + unusedHint);
        Assert.isTrue(dailyProblems.contains('no value for scheduled runs'), 'A Daily job needs a scheduled value: ' + dailyProblems);
        Assert.isFalse(testOnlyProblems.contains('since'), 'A Test Only job only needs the test value: ' + testOnlyProblems);
        Assert.isTrue(notJsonProblems.contains('must be JSON'), 'Old-style parameters should be refused: ' + notJsonProblems);
        Assert.isTrue(badJsonProblems.contains('not valid JSON'), 'Broken JSON should be refused: ' + badJsonProblems);
    }

    /**
     * @description Verifies FieldShift's field values must name distinct updateable fields, and that other jobs are
     * warned their field values are ignored.
     */
    @IsTest
    static void fieldValueChecks() {
        JobSequenceManagerController.SequenceJob job = validJob();
        job.jobType = 'Function';
        job.executionJob = 'FieldShift';
        job.parameters = JSON.serialize(new Map<String, Object>{
            'fieldValues' => new List<Object>{
                new Map<String, Object>{'field' => 'AboutMe', 'value' => 'Updated'},
                new Map<String, Object>{'field' => 'aboutme', 'value' => 'Again'},
                new Map<String, Object>{'field' => 'NoSuchField__c', 'value' => 'x'}
            }
        });
        JobSequenceManagerController.SequenceJob empty = validJob();
        empty.jobType = 'Function';
        empty.executionJob = 'FieldShift';
        JobSequenceManagerController.SequenceJob dmlJob = validJob();
        dmlJob.parameters = job.parameters;

        Test.startTest();
        JobSequenceVariables.Issues fieldShift = JobSequenceManagerController.checkParameters(job);
        JobSequenceVariables.Issues none = JobSequenceManagerController.checkParameters(empty);
        JobSequenceVariables.Issues dml = JobSequenceManagerController.checkParameters(dmlJob);
        Test.stopTest();

        String problems = String.join(fieldShift.problems, ' ');
        Assert.isTrue(problems.contains('set twice'), 'A field set twice should be refused: ' + problems);
        Assert.isTrue(problems.contains('NoSuchField__c is not an updateable field'), 'An unknown field should be refused: ' + problems);
        Assert.isFalse(problems.contains('AboutMe is not'), 'AboutMe is updateable: ' + problems);
        Assert.isTrue(String.join(none.problems, ' ').contains('at least one field value'), 'FieldShift needs a field value');
        Assert.isTrue(String.join(dml.warnings, ' ').contains('only used by the FieldShift'), 'A DML job should be warned');
    }

    /**
     * @description Verifies the built query is returned as written and resolved, with the parameter problems and
     * warnings, and that a token that cannot be resolved is reported.
     */
    @IsTest
    static void buildQueryShowsBothVersions() {
        JobSequenceManagerController.SequenceJob job = validJob();
        job.whereClause = 'IsActive = true AND Alias IN {!Var.aliases} AND LastModifiedDate <= {!Now}';
        job.parameters = variableParameters('aliases', 'TextList', 'a, b', 'c');
        JobSequenceManagerController.SequenceJob plain = validJob();
        JobSequenceManagerController.SequenceJob bad = validJob();
        bad.whereClause = 'IsActive = true {!Nope}';

        Test.startTest();
        JobSequenceManagerController.BuiltQuery scheduled = JobSequenceManagerController.buildQuery(JSON.serialize(job), false);
        JobSequenceManagerController.BuiltQuery asTest = JobSequenceManagerController.buildQuery(JSON.serialize(job), true);
        JobSequenceManagerController.BuiltQuery noVariables = JobSequenceManagerController.buildQuery(JSON.serialize(plain), false);
        JobSequenceManagerController.BuiltQuery broken = JobSequenceManagerController.buildQuery(JSON.serialize(bad), false);
        Test.stopTest();

        Assert.isTrue(scheduled.queryWithVariables.contains('{!Var.aliases}'), 'The written query should keep the token');
        Assert.isTrue(scheduled.query.contains('Alias IN (\'a\',\'b\')'), 'The list should be quoted: ' + scheduled.query);
        Assert.isTrue(asTest.query.contains('Alias IN (\'c\')'), 'The test value should be used: ' + asTest.query);
        Assert.isTrue(scheduled.problems.isEmpty(), 'No problems expected: ' + scheduled.problems);
        Assert.isNull(noVariables.queryWithVariables, 'Without tokens only one version is needed');
        Assert.isTrue(String.join(broken.problems, ' ').contains('Unknown token'), 'A bad token should be a save problem: ' + broken.problems);
        Assert.isNull(broken.errorMessage, 'The problem is not repeated as the build error');
    }

    /**
     * @description Verifies the deploy callback turns failures into a platform event message and publishes it.
     */
    @IsTest
    static void deployCallbackPublishesResult() {
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.id = '0Af000000000001AAA';
        result.status = Metadata.DeployStatus.Failed;
        result.details = new Metadata.DeployDetails();
        Metadata.DeployMessage failure = new Metadata.DeployMessage();
        failure.fullName = 'Sequence_Job.NEW_DAILY_JOB';
        failure.problem = 'You have selected an invalid job execution';
        result.details.componentFailures = new List<Metadata.DeployMessage>{failure};

        Test.startTest();
        Job_Sequencer_Deploy_Result__e event = JobSequenceDeployCallback.buildEvent(result);
        new JobSequenceDeployCallback().handleResult(result, null);
        Test.stopTest();

        Assert.areEqual('Failed', event.Status__c, 'The status should be reported');
        Assert.isTrue(event.Message__c.contains('invalid job execution'), 'The failure should be in the message');
        Assert.areEqual('0Af000000000001AAA', event.DeploymentId__c, 'The deployment Id should be reported');
    }

    /**
     * @description Verifies only One Time jobs can be run standalone.
     */
    @IsTest
    static void runStandaloneRefusesOtherFrequencies() {
        String message;
        Test.startTest();
        try {
            JobSequenceManagerController.runStandalone('JOBSEQ_PURGE_RUNS');
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(message.contains('only One Time jobs'), 'A Daily job should be refused: ' + message);
    }
}
