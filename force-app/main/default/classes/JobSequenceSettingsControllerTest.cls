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
 * @description: **JobSequenceSettingsControllerTest** -- Unit tests for JobSequenceSettingsController: default values,
 * creating and updating the org default settings, and rejecting invalid values.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Add Run Timeout setting                                 |
 *   |  10/16/2026 |  Gary Butler      | Add Run and Error History Days settings                 |
 *
 */
@IsTest
private class JobSequenceSettingsControllerTest {

    /**
     * @description Verifies the field defaults are returned when no org default settings exist.
     */
    @IsTest
    static void getSettingsReturnsDefaultsWhenNoneSaved() {
        Test.startTest();
        Sequence_Jobs_Settings__c settings = JobSequenceSettingsController.getSettings();
        Test.stopTest();

        Assert.isNull(settings.Id, 'No settings record should exist yet');
        Assert.isTrue(settings.Enabled__c, 'Enabled should default to true');
        Assert.areEqual(10, settings.MaxRetries__c, 'Max Retries should default to 10');
        Assert.areEqual(5, settings.MinutesUntilRetry__c, 'Minutes Until Retry should default to 5');
        Assert.areEqual(60, settings.RunTimeoutMinutes__c, 'Run Timeout should default to 60');
        Assert.areEqual(30, settings.RunRetentionDays__c, 'Run History Days should default to 30');
        Assert.areEqual(30, settings.ErrorRetentionDays__c, 'Error History Days should default to 30');
    }

    /**
     * @description Verifies the first save creates the org default record and a second save updates the same record.
     */
    @IsTest
    static void saveSettingsCreatesThenUpdatesOrgDefault() {
        Test.startTest();
        Sequence_Jobs_Settings__c created = JobSequenceSettingsController.saveSettings(false, 3, 15, 30, 30, 30);
        Sequence_Jobs_Settings__c updated = JobSequenceSettingsController.saveSettings(true, 7, 20, 90, 14, 60);
        Test.stopTest();

        Assert.isNotNull(created.Id, 'The org default settings should have been created');
        Assert.areEqual(created.Id, updated.Id, 'The second save should update the same record');

        Sequence_Jobs_Settings__c stored = Sequence_Jobs_Settings__c.getOrgDefaults();
        Assert.areEqual(UserInfo.getOrganizationId(), stored.SetupOwnerId, 'The settings should be the org default');
        Assert.isTrue(stored.Enabled__c, 'Enabled should be updated');
        Assert.areEqual(7, stored.MaxRetries__c, 'Max Retries should be updated');
        Assert.areEqual(20, stored.MinutesUntilRetry__c, 'Minutes Until Retry should be updated');
        Assert.areEqual(90, stored.RunTimeoutMinutes__c, 'Run Timeout should be updated');
        Assert.areEqual(14, stored.RunRetentionDays__c, 'Run History Days should be updated');
        Assert.areEqual(60, stored.ErrorRetentionDays__c, 'Error History Days should be updated');
        Assert.areEqual(stored.Id, JobSequenceSettingsController.getSettings().Id, 'getSettings should return the saved record');
    }

    /**
     * @description Verifies missing and out-of-range values are rejected without saving anything.
     */
    @IsTest
    static void saveSettingsRejectsInvalidValues() {
        List<List<Object>> invalidInputs = new List<List<Object>>{
                new List<Object>{null, 10, 5, 60, 30, 30},
                new List<Object>{true, null, 5, 60, 30, 30},
                new List<Object>{true, -1, 5, 60, 30, 30},
                new List<Object>{true, JobSequenceSettingsController.MAX_RETRIES_LIMIT + 1, 5, 60, 30, 30},
                new List<Object>{true, 10, 0, 60, 30, 30},
                new List<Object>{true, 10, JobSequenceSettingsController.MINUTES_UNTIL_RETRY_LIMIT + 1, 60, 30, 30},
                new List<Object>{true, 10, 5, null, 30, 30},
                new List<Object>{true, 10, 5, 0, 30, 30},
                new List<Object>{true, 10, 5, 60, 0, 30},
                new List<Object>{true, 10, 5, 60, 30, null}
        };

        Test.startTest();
        for (List<Object> input : invalidInputs) {
            Boolean errorThrown = false;
            try {
                JobSequenceSettingsController.saveSettings((Boolean) input[0], (Integer) input[1], (Integer) input[2], (Integer) input[3],
                        (Integer) input[4], (Integer) input[5]);
            } catch (AuraHandledException e) {
                errorThrown = String.isNotBlank(e.getMessage());
            }
            Assert.isTrue(errorThrown, 'Invalid input should be rejected: ' + input);
        }
        Test.stopTest();

        Assert.isNull(Sequence_Jobs_Settings__c.getOrgDefaults().Id, 'No settings should have been saved');
    }
}
