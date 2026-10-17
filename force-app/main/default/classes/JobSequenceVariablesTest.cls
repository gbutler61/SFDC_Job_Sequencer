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
 * @description: **JobSequenceVariablesTest** -- Tests for JobSequenceVariables (reading Job Parameters JSON, typed
 * variables, lookup tokens and the parameter checks), for JobSequence building its query, field values and handler
 * parameters from them, and for JobSequenceQueueable tagging errors with its job Id.
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
private class JobSequenceVariablesTest {

    /**
     * @description Builds a definition with one variable.
     *
     * @param type      The variable type
     * @param value     The value for scheduled runs
     * @param testValue The value when Test.isRunningTest() is true
     *
     * @return The definition
     */
    private static JobSequenceVariables.Definition oneVariable(String type, String value, String testValue) {
        JobSequenceVariables.Variable v = new JobSequenceVariables.Variable();
        v.name = 'x';
        v.type = type;
        v.value = value;
        v.testValue = testValue;
        JobSequenceVariables.Definition definition = JobSequenceVariables.parse(null);
        definition.variables.add(v);
        return definition;
    }

    /**
     * @description Resolves {!Var.x} for a scheduled run.
     *
     * @param type  The variable type
     * @param value The value
     *
     * @return The SOQL literal
     */
    private static String soql(String type, String value) {
        return new JobSequenceVariables.Resolver(oneVariable(type, value, null), false).resolveQuery('{!Var.x}');
    }

    /**
     * @description Resolves {!Var.x} for a scheduled run and returns the error message.
     *
     * @param type  The variable type
     * @param value The value
     *
     * @return The message, or null when it resolved
     */
    private static String errorFor(String type, String value) {
        try {
            soql(type, value);
        } catch (JobSequenceException e) {
            return e.getMessage();
        }
        return null;
    }

    /**
     * @description Builds an in-memory Sequence Job.
     *
     * @param whereClause The Where
     * @param parameters  The Job Parameters JSON
     *
     * @return The record
     */
    private static Sequence_Job__mdt job(String whereClause, String parameters) {
        return new Sequence_Job__mdt(Select__c = 'Id', From__c = 'User', Where__c = whereClause, Parameters__c = parameters, BatchLimit__c = 200);
    }

    /**
     * @description Verifies each type becomes the right SOQL literal.
     */
    @IsTest
    static void typesBecomeSoqlLiterals() {
        Test.startTest();
        Assert.areEqual('\'O\\\'Brien\'', soql('Text', 'O\'Brien'), 'Text should be quoted and escaped');
        Assert.areEqual('5', soql('Number', '5.0'), 'Numbers lose trailing zeros');
        Assert.areEqual('true', soql('Boolean', 'TRUE'), 'Booleans are lower case');
        Assert.areEqual('2026-10-17', soql('Date', '2026-10-17'), 'Dates are yyyy-mm-dd');
        Assert.areEqual('2026-10-17T15:00:00Z', soql('DateTime', '2026-10-17T15:00:00.000Z'), 'Date/times are GMT ISO');
        Assert.areEqual(String.valueOf(Datetime.now().dateGmt().addDays(-7)), soql('RelativeDate', '-1 week'), 'Weeks count as 7 days');
        Assert.areEqual('(\'A\',\'B\')', soql('TextList', 'A, ,B'), 'Lists are quoted, blanks skipped');
        Assert.areEqual('AND IsActive = true', soql('SoqlFragment', 'AND IsActive = true'), 'Fragments are inserted as written');
        Assert.areEqual('', soql('SoqlFragment', null), 'A blank fragment is allowed');
        Assert.isTrue(soql('RelativeDateTime', '+2 hours').startsWith('20'), 'Relative date/times are GMT ISO');
        Assert.isTrue(soql('relativedatetime', '-1 months').endsWith('Z'), 'Types match without regard to case');
        Test.stopTest();
    }

    /**
     * @description Verifies values that don't fit their type, and missing values, are reported.
     */
    @IsTest
    static void badValuesAreReported() {
        Test.startTest();
        Assert.isTrue(errorFor('Number', 'five').contains('must be a number'), 'A non-number should be reported');
        Assert.isTrue(errorFor('Boolean', 'yes').contains('true or false'), 'A non-boolean should be reported');
        Assert.isTrue(errorFor('Date', 'tomorrow').contains('must be a date'), 'A non-date should be reported');
        Assert.isTrue(errorFor('DateTime', 'soon').contains('must be a date/time'), 'A non-date/time should be reported');
        Assert.isTrue(errorFor('RelativeDate', '-2 hours').contains('days, weeks, months or years'), 'Hours are not a date amount');
        Assert.isTrue(errorFor('RelativeDateTime', 'yesterday').contains('-2 hours'), 'A bad amount should be reported');
        Assert.isTrue(errorFor('TextList', ' , ').contains('at least one item'), 'An empty list should be reported');
        Assert.isTrue(errorFor('Text', '').contains('no value for scheduled runs'), 'A missing value should be reported');
        Assert.isTrue(errorFor('Colour', 'red').contains('unknown type'), 'An unknown type should be reported');
        Test.stopTest();
    }

    /**
     * @description Verifies the test value is used when Test.isRunningTest() is true, and the value when it is blank.
     */
    @IsTest
    static void testValueIsUsedInTests() {
        Test.startTest();
        String withTestValue = new JobSequenceVariables.Resolver(oneVariable('Text', 'live', 'test'), true).resolveQuery('{!Var.x}');
        String withoutTestValue = new JobSequenceVariables.Resolver(oneVariable('Text', 'live', ''), true).resolveQuery('{!Var.x}');
        String scheduled = new JobSequenceVariables.Resolver(oneVariable('Text', 'live', 'test'), false).resolveQuery('{!Var.x}');
        Test.stopTest();

        Assert.areEqual('\'test\'', withTestValue, 'The test value should be used');
        Assert.areEqual('\'live\'', withoutTestValue, 'A blank test value falls back to the value');
        Assert.areEqual('\'live\'', scheduled, 'Scheduled runs use the value');
    }

    /**
     * @description Verifies the lookup and built-in tokens, in queries and in plain values, and that unknown tokens
     * and undefined variables are reported.
     */
    @IsTest
    static void lookupTokensResolve() {
        JobSequenceVariables.Resolver resolver = new JobSequenceVariables.Resolver(JobSequenceVariables.parse(''), false);

        Test.startTest();
        String label = resolver.resolveValue('{!Label.Job_Sequence_Error_Email_Subject}');
        String mdt = resolver.resolveValue('{!Mdt.Sequence_Job__mdt.TEST_FIELDSHIFT_FUNCTION.From__c}');
        String userQuery = resolver.resolveQuery('OwnerId = {!UserId} AND CreatedDate <= {!Now} AND CloseDate = {!Today}');
        String userValue = resolver.resolveValue('{! UserId }');
        List<String> errors = new List<String>();
        for (String bad : new List<String>{'{!Nope}', '{!Var.missing}', '{!Label.No_Such_Label_Here}', '{!Mdt.Sequence_Job__mdt.NO_SUCH_JOB.From__c}',
                '{!Mdt.Sequence_Job__mdt.From__c}', '{!Mdt.Sequence_Job__mdt.TEST_FIELDSHIFT_FUNCTION.NoSuchField__c}', '{!Label.Bad-Name}'}) {
            try {
                resolver.resolveQuery(bad);
                errors.add('resolved: ' + bad);
            } catch (JobSequenceException e) {
                errors.add(e.getMessage());
            }
        }
        Test.stopTest();

        Assert.areEqual(System.Label.Job_Sequence_Error_Email_Subject, label, 'The label value should be inserted');
        Assert.areEqual('User', mdt, 'The custom metadata value should be inserted');
        Assert.isTrue(userQuery.contains('OwnerId = \'' + UserInfo.getUserId() + '\''), 'The user Id should be quoted in SOQL');
        Assert.isTrue(userQuery.contains('CloseDate = ' + String.valueOf(Datetime.now().dateGmt())), 'Today should be a date');
        Assert.areEqual(UserInfo.getUserId(), userValue, 'Plain values are not quoted');
        Assert.isTrue(errors[0].contains('Unknown token'), errors[0]);
        Assert.isTrue(errors[1].contains('no variable named missing'), errors[1]);
        Assert.isTrue(errors[2].contains('no custom label'), errors[2]);
        Assert.isTrue(errors[3].contains('no record named'), errors[3]);
        for (Integer i = 4; i < errors.size(); i++) {
            Assert.isFalse(errors[i].startsWith('resolved'), 'Should be refused: ' + errors[i]);
        }
    }

    /**
     * @description Verifies reading Job Parameters: blank, not JSON, broken JSON and missing lists.
     */
    @IsTest
    static void parseReadsJobParameters() {
        Test.startTest();
        JobSequenceVariables.Definition blank = JobSequenceVariables.parse('  ');
        JobSequenceVariables.Definition partial = JobSequenceVariables.parse('{"variables":[{"name":"a","type":"Text","value":"b"}]}');
        List<String> messages = new List<String>();
        for (String bad : new List<String>{'StageName:Closed', '{"variables": ['}) {
            try {
                JobSequenceVariables.parse(bad);
            } catch (JobSequenceException e) {
                messages.add(e.getMessage());
            }
        }
        Test.stopTest();

        Assert.areEqual(1, blank.version, 'The version defaults to 1');
        Assert.isTrue(blank.variables.isEmpty() && blank.fieldValues.isEmpty() && blank.handlerParameters.isEmpty(), 'Blank gives empty lists');
        Assert.areEqual(1, partial.variables.size(), 'The variable should be read');
        Assert.isTrue(partial.fieldValues.isEmpty(), 'Missing lists become empty');
        Assert.isTrue(messages[0].contains('must be JSON'), messages[0]);
        Assert.isTrue(messages[1].contains('not valid JSON'), messages[1]);
    }

    /**
     * @description Verifies the checks: names, duplicates, types, handler parameter names, unresolvable values in
     * either context, and unused variables.
     */
    @IsTest
    static void checkFindsProblemsAndWarnings() {
        JobSequenceVariables.Definition badNames = JobSequenceVariables.parse(
            '{"variables":[{"name":"1st","type":"Text","value":"a"},{"name":"dup","type":"Text","value":"a"},'
            + '{"name":"DUP","type":"Text","value":"a"},{"name":"untyped","value":"a"}],"handlerParameters":{"":"x"}}');
        JobSequenceVariables.Definition testOnly = JobSequenceVariables.parse(
            '{"variables":[{"name":"since","type":"RelativeDateTime","testValue":"-1 minutes"},{"name":"spare","type":"Text","value":"a"}],'
            + '"fieldValues":[{"field":"AboutMe","value":"{!Var.since}"}]}');

        Test.startTest();
        JobSequenceVariables.Issues names = JobSequenceVariables.check(badNames, '', false);
        JobSequenceVariables.Issues scheduled = JobSequenceVariables.check(testOnly, 'LastModifiedDate >= {!Var.since}', false);
        JobSequenceVariables.Issues asTestOnly = JobSequenceVariables.check(testOnly, 'LastModifiedDate >= {!Var.since}', true);
        Test.stopTest();

        String nameProblems = String.join(names.problems, ' ');
        Assert.isTrue(nameProblems.contains('"1st" must start with a letter'), nameProblems);
        Assert.isTrue(nameProblems.contains('Two variables are named DUP'), nameProblems);
        Assert.isTrue(nameProblems.contains('untyped needs a type'), nameProblems);
        Assert.isTrue(nameProblems.contains('Every handler parameter needs a name'), nameProblems);
        Assert.isTrue(String.join(scheduled.problems, ' ').contains('no value for scheduled runs'), 'A scheduled run needs a value');
        Assert.isTrue(asTestOnly.problems.isEmpty(), 'A Test Only job only needs the test value: ' + asTestOnly.problems);
        Assert.areEqual(1, asTestOnly.warnings.size(), 'Only the spare variable is unused: ' + asTestOnly.warnings);
        Assert.isTrue(asTestOnly.warnings[0].contains('spare'), asTestOnly.warnings[0]);
    }

    /**
     * @description Verifies JobSequence builds its query, field values and handler parameters from the JSON, keeps
     * the query as written, and resolves settings tokens.
     */
    @IsTest
    static void jobSequenceUsesTheParameters() {
        String parameters = '{"variables":[{"name":"alias","type":"Text","value":"live","testValue":"tst"}],'
            + '"fieldValues":[{"field":"AboutMe","value":"Hi {!Var.alias}"},{"field":"Title","blank":true}],'
            + '"handlerParameters":{"MyCustom":"{!Var.alias}"}}';

        Test.startTest();
        JobSequence inTest = new JobSequence(job('Alias = {!Var.alias} AND IsActive = true', parameters));
        JobSequence.useTestParameters = false;
        JobSequence scheduled = new JobSequence(job('Alias = {!Var.alias}', parameters));
        JobSequence.useTestParameters = null;
        JobSequence noParameters = new JobSequence(job('IsActive = true', null));
        Test.stopTest();

        Assert.isTrue(inTest.query.contains('Alias = \'tst\''), 'Tests use the test value: ' + inTest.query);
        Assert.isTrue(inTest.queryTemplate.contains('{!Var.alias}'), 'The query as written keeps the token');
        Assert.isTrue(scheduled.query.contains('Alias = \'live\''), 'Scheduled runs use the value: ' + scheduled.query);
        Assert.areEqual('Hi tst', inTest.fieldValuesByField.get('aboutme'), 'Field values resolve tokens as plain text');
        Assert.areEqual('null', inTest.fieldValuesByField.get('title'), 'A blank field value clears the field');
        Assert.areEqual('tst', inTest.paramStringsByStrings.get('mycustom'), 'Handler parameters keep lower-case names');
        Assert.isNull(noParameters.paramStringsByStrings, 'Without handler parameters the map stays null');
        Assert.isTrue(noParameters.fieldValuesByField.isEmpty(), 'Without field values the map is empty');
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
