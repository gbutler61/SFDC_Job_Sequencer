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
     * @description Verifies Test Query explains when DateTimeVar or test parameters have nothing to fill in the Where.
     */
    @IsTest
    static void testQueryHintsAtUnusedParameters() {
        JobSequenceManagerController.SequenceJob timeJob = validJob();
        timeJob.parameters = '!Test.isRunningTest:"DateTimeVar=-1440",Test.isRunningTest:"DateTimeVar=-1"';
        JobSequenceManagerController.SequenceJob swapJob = validJob();
        swapJob.parameters = '!Test.isRunningTest:"AND LastModifiedDate != TODAY"';
        JobSequenceManagerController.SequenceJob fineJob = validJob();
        fineJob.parameters = timeJob.parameters;
        fineJob.whereClause = 'IsActive = true AND LastModifiedDate >= :DateTimeVar';

        Test.startTest();
        JobSequenceManagerController.TestQueryResult timeResult = JobSequenceManagerController.testQuery(JSON.serialize(timeJob), false);
        JobSequenceManagerController.TestQueryResult swapResult = JobSequenceManagerController.testQuery(JSON.serialize(swapJob), false);
        JobSequenceManagerController.TestQueryResult fineResult = JobSequenceManagerController.testQuery(JSON.serialize(fineJob), false);
        Test.stopTest();

        Assert.isTrue(timeResult.queryHint.contains(':DateTimeVar'), 'A missing :DateTimeVar should be pointed out');
        Assert.isTrue(swapResult.queryHint.contains('{0}'), 'A missing {0} should be pointed out');
        Assert.isTrue(fineResult.isValid, 'The time filter query should run: ' + fineResult.errorMessage);
        Assert.isNull(fineResult.queryHint, 'No hint when the Where uses :DateTimeVar');
        Assert.isTrue(fineResult.query.contains('LastModifiedDate >= 20'), 'The date/time should be filled in: ' + fineResult.query);

        JobSequenceManagerController.SequenceJob unsetJob = validJob();
        unsetJob.whereClause = 'IsActive = true AND LastModifiedDate >= :g_DateTimeVar';
        Assert.isTrue(JobSequenceManagerController.getUnusedParameterHint(unsetJob).contains('Variable does not exist'),
                'A :DateTimeVar the parameters never set should be pointed out');

        // Jason's pattern: only the unit-test value. Fine for a Test Only job, refused for a scheduled one
        JobSequenceManagerController.SequenceJob testOnlyValue = validJob();
        testOnlyValue.whereClause = 'IsActive = true AND LastModifiedDate >= :g_DateTimeVar';
        testOnlyValue.parameters = 'Test.isRunningTest:DateTimeVar=-1';
        Assert.isTrue(JobSequenceManagerController.getParameterIssue(testOnlyValue).blocksSave, 'A Daily job needs a normal-run value');
        testOnlyValue.frequency = 'Test Only';
        Assert.isFalse(JobSequenceManagerController.getParameterIssue(testOnlyValue).blocksSave, 'A Test Only job only runs in tests');

        // Only the normal-run value: warned about, but it can be saved
        JobSequenceManagerController.SequenceJob normalOnly = validJob();
        normalOnly.whereClause = 'IsActive = true AND LastModifiedDate >= :DateTimeVar';
        normalOnly.parameters = '!Test.isRunningTest:"DateTimeVar=-60"';
        JobSequenceManagerController.ParameterIssue normalOnlyIssue = JobSequenceManagerController.getParameterIssue(normalOnly);
        Assert.isTrue(normalOnlyIssue.message.contains('Test.isRunningTest() is true'), 'A missing test value should be pointed out');
        Assert.isFalse(normalOnlyIssue.blocksSave, 'A missing unit-test value should not block the save');

        JobSequenceManagerController.recordsOverride = new List<Sequence_Job__mdt>();
        Assert.isTrue(String.join(JobSequenceManagerController.validate(swapJob, true), ' ').contains('{0}'),
                'Saving test conditions without {0} should be refused');
        Assert.isFalse(String.join(JobSequenceManagerController.validate(fineJob, true), ' ').contains('DateTimeVar'),
                'A time filter the Where uses should save');
    }

    /**
     * @description Verifies Test Query can build Jason's Test Only pattern (unit-test value only) as a unit test would,
     * and explains why the normal-run version fails.
     */
    @IsTest
    static void testQueryAsUnitTest() {
        JobSequenceManagerController.SequenceJob job = validJob();
        job.frequency = 'Test Only';
        job.whereClause = 'IsActive = true AND LastModifiedDate >= :g_DateTimeVar';
        job.parameters = 'Test.isRunningTest:DateTimeVar=-1';

        Test.startTest();
        JobSequenceManagerController.TestQueryResult asTest = JobSequenceManagerController.testQuery(JSON.serialize(job), true);
        JobSequenceManagerController.TestQueryResult asNormal = JobSequenceManagerController.testQuery(JSON.serialize(job), false);
        Test.stopTest();

        Assert.isTrue(asTest.isValid, 'As a unit test the query should be valid: ' + asTest.errorMessage);
        Assert.isTrue(asTest.query.contains('LastModifiedDate >= 20'), 'The unit-test value should be filled in: ' + asTest.query);
        Assert.isTrue(asTest.queryWithVariables.contains(':g_DateTimeVar'), 'The query as written should keep the variable');
        Assert.isTrue(asNormal.isValid, 'As a normal run the unit-test value is borrowed so the query can be checked: ' + asNormal.errorMessage);
        Assert.isTrue(asNormal.queryWithVariables.contains(':g_DateTimeVar'), 'Both versions should be shown');
        Assert.isTrue(asNormal.queryNote.contains('scheduled runs'), 'The borrowed value should be explained: ' + asNormal.queryNote);
    }

    /**
     * @description Verifies the built query is returned as written and filled in, for normal runs and unit tests.
     */
    @IsTest
    static void buildQueryShowsBothVersions() {
        JobSequenceManagerController.SequenceJob job = validJob();
        job.whereClause = 'IsActive = true AND LastModifiedDate >= :DateTimeVar';
        job.parameters = '!Test.isRunningTest:"DateTimeVar=-1440",Test.isRunningTest:"DateTimeVar=-1"';
        JobSequenceManagerController.SequenceJob plain = validJob();
        JobSequenceManagerController.SequenceJob bad = validJob();
        bad.parameters = 'NoColonHere';

        Test.startTest();
        JobSequenceManagerController.BuiltQuery normal = JobSequenceManagerController.buildQuery(JSON.serialize(job), false);
        JobSequenceManagerController.BuiltQuery asTest = JobSequenceManagerController.buildQuery(JSON.serialize(job), true);
        JobSequenceManagerController.BuiltQuery noVariables = JobSequenceManagerController.buildQuery(JSON.serialize(plain), false);
        JobSequenceManagerController.BuiltQuery broken = JobSequenceManagerController.buildQuery(JSON.serialize(bad), false);
        Test.stopTest();

        Assert.isTrue(normal.queryWithVariables.contains(':DateTimeVar'), 'The written query should keep the variable');
        Assert.isFalse(normal.query.contains(':DateTimeVar'), 'The running query should have it filled in');
        Assert.areNotEqual(normal.query, asTest.query, 'Normal runs and unit tests use different values');
        Assert.isNull(noVariables.queryWithVariables, 'Without variables only one version is needed');
        Assert.isNull(normal.note, 'Both values are set, so nothing is borrowed');
        Assert.isTrue(broken.errorMessage.contains('NoColonHere'), 'A build error should be reported');
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
}
