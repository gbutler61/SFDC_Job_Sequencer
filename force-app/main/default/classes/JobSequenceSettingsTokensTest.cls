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
 * @description: **JobSequenceSettingsTokensTest** -- Unit tests for JobSequenceSettingsTokens: replacing settings tokens
 * with saved and default values, and rejecting unknown or empty tokens.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
@IsTest
private class JobSequenceSettingsTokensTest {

    /**
     * @description Verifies text without tokens is returned unchanged.
     */
    @IsTest
    static void textWithoutTokensIsUnchanged() {
        Assert.areEqual('IsActive = true', JobSequenceSettingsTokens.apply('IsActive = true'), 'Text without tokens should not change');
        Assert.isNull(JobSequenceSettingsTokens.apply(null), 'Blank text should stay blank');
    }

    /**
     * @description Verifies tokens use the field default when nothing is saved, and the saved value once it is.
     */
    @IsTest
    static void tokensUseDefaultThenSavedValues() {
        String whereClause = 'CreatedDate < LAST_N_DAYS:{!Settings.RunRetentionDays__c} AND IsDeleted = {!Settings.Enabled__c}';

        Test.startTest();
        String withDefaults = JobSequenceSettingsTokens.apply(whereClause);
        JobSequenceSettingsController.saveSettings(false, 10, 5, 60, 14, 30);
        String withSaved = JobSequenceSettingsTokens.apply(whereClause);
        Test.stopTest();

        Assert.areEqual('CreatedDate < LAST_N_DAYS:30 AND IsDeleted = true', withDefaults, 'The defaults should be used');
        Assert.areEqual('CreatedDate < LAST_N_DAYS:14 AND IsDeleted = false', withSaved, 'The saved values should be used');
    }

    /**
     * @description Verifies an unknown field and a field without a value are rejected with a clear message.
     */
    @IsTest
    static void unknownOrEmptyTokensAreRejected() {
        String unknownMessage;
        String emptyMessage;
        Test.startTest();
        try {
            JobSequenceSettingsTokens.apply('LAST_N_DAYS:{!Settings.NoSuchField__c}');
        } catch (JobSequenceException e) {
            unknownMessage = e.getMessage();
        }
        try {
            JobSequenceSettingsTokens.apply('Name = {!Settings.Name}');
        } catch (JobSequenceException e) {
            emptyMessage = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(unknownMessage.contains('NoSuchField__c'), 'The unknown field should be named');
        Assert.isTrue(emptyMessage.contains('has no value'), 'An empty setting should be reported');
    }

    /**
     * @description Verifies the sequencer applies tokens when it builds a job's query, as the packaged cleanup jobs need.
     */
    @IsTest
    static void builtQueryAppliesTokens() {
        Sequence_Job__mdt sj = new Sequence_Job__mdt(
                Select__c = 'Id',
                From__c = 'Job_Sequence_Run__c',
                Where__c = 'CreatedDate < LAST_N_DAYS:{!Settings.RunRetentionDays__c}',
                BatchLimit__c = 200
        );

        Test.startTest();
        String query = new JobSequence(sj).query;
        List<SObject> rows = Database.query(query, AccessLevel.SYSTEM_MODE);
        Test.stopTest();

        Assert.areEqual('SELECT Id FROM Job_Sequence_Run__c WHERE CreatedDate < LAST_N_DAYS:30', query, 'The token should be replaced and ORDER BY left out');
        Assert.isTrue(rows.isEmpty(), 'The built query should run');
    }
}
