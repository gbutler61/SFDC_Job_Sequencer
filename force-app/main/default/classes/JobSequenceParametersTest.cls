/**
 * @description: **JobSequenceParametersTest** -- Unit tests for the Job Parameters fixes in JobSequence (values with
 * commas and colons, the {0} test swap) and for JobSequenceQueueable tagging errors with its job Id.
 * @author: Gary Butler
 * @date: 10/17/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/17/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
@IsTest
private class JobSequenceParametersTest {

    /**
     * @description Builds an in-memory Sequence Job with a simple User query.
     *
     * @param whereClause The Where text
     * @param parameters  The Job Parameters text
     *
     * @return The record
     */
    private static Sequence_Job__mdt job(String whereClause, String parameters) {
        return new Sequence_Job__mdt(Select__c = 'Id', From__c = 'User', Where__c = whereClause, Parameters__c = parameters, BatchLimit__c = 200);
    }

    /**
     * @description Verifies entries split only on commas outside quotes, and blank entries are skipped.
     */
    @IsTest
    static void splitKeepsQuotedCommas() {
        List<String> entries = JobSequence.splitParameters('StageName:"Closed, Lost", Description__c:Plain,, ');
        Assert.areEqual(2, entries.size(), 'The quoted comma should not split, and the blank entry should be skipped');
        Assert.areEqual('StageName:"Closed, Lost"', entries[0], 'The quoted value should stay whole');
    }

    /**
     * @description Verifies values keep their colons, e.g. date/times and LAST_N_DAYS:n in a test swap.
     */
    @IsTest
    static void valuesKeepTheirColons() {
        JobSequence js = new JobSequence(job('IsActive = true {0}',
                'Test.isRunningTest:"AND CreatedDate = LAST_N_DAYS:7", LastLoginDate:2026-01-01T10:00:00.000Z'));

        Assert.areEqual('2026-01-01T10:00:00.000Z', js.paramStringsByStrings.get('lastlogindate'), 'The date/time should keep its colons');
        Assert.areEqual('SELECT Id FROM User WHERE IsActive = true AND CreatedDate = LAST_N_DAYS:7', js.query, 'The test swap should keep LAST_N_DAYS:7');
        Assert.isNotNull(Database.query(js.query, AccessLevel.SYSTEM_MODE), 'The query should run');
    }

    /**
     * @description Verifies {0} is blanked when only the other context has a value, so the query stays valid.
     */
    @IsTest
    static void missingContextValueBlanksThePlaceholder() {
        JobSequence js = new JobSequence(job('Alias != \'x\' {0}', '!Test.isRunningTest:"AND LastModifiedDate != TODAY"'));

        Assert.areEqual('SELECT Id FROM User WHERE Alias != \'x\'', js.query.trim(), 'The placeholder should be blank and the quotes intact');
        Assert.isNotNull(Database.query(js.query, AccessLevel.SYSTEM_MODE), 'The query should run');
    }

    /**
     * @description Verifies a parameter without a colon is reported clearly.
     */
    @IsTest
    static void parameterWithoutColonIsRejected() {
        String message;
        try {
            new JobSequence(job('IsActive = true', 'JustAName'));
        } catch (JobSequenceException e) {
            message = e.getMessage();
        }
        Assert.isTrue(message.contains('JustAName'), 'The bad parameter should be named');
    }

    /**
     * @description Verifies an error in a queueable job is logged against that job's Id, which its error email uses.
     */
    @IsTest
    static void queueableErrorsCarryTheJobId() {
        Sequence_Job__mdt sj = (Sequence_Job__mdt) Database.query(JobSequenceQueueable.constructSequenceJobQuery('Test Only'), AccessLevel.SYSTEM_MODE)[0];
        sj.ExecutionJob__c = 'thisIsNotAValidFunction';
        sj.IsBatchJob__c = false;
        JobSequence js = new JobSequence(sj);

        Test.startTest();
        Id jobId = System.enqueueJob(new JobSequenceQueueable(js, true));
        Test.stopTest();

        List<Job_Sequence_Error__c> errors = [SELECT BatchJobId__c FROM Job_Sequence_Error__c WITH SYSTEM_MODE];
        Assert.isFalse(errors.isEmpty(), 'The unknown function should be logged');
        Assert.areEqual(String.valueOf(jobId).left(15), errors[0].BatchJobId__c.left(15), 'The error should carry the queueable job Id');
    }
}
