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
 * @description: **JobSequenceSettingsTokens** -- Replaces {!Settings.FieldName__c} tokens in a sequence job's query
 * and parameters with that field's value from the Sequence Jobs Settings custom setting, so jobs can be configured
 * from settings (e.g. LAST_N_DAYS:{!Settings.RunRetentionDays__c}).
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
public with sharing class JobSequenceSettingsTokens {
    private static final String TOKEN_START = '{!Settings.';
    private static final Pattern TOKEN_PATTERN = Pattern.compile('\\{!Settings\\.([A-Za-z0-9_]+)\\}');

    /**
     * @description Replaces every settings token in the text. Values come from the running user's effective Sequence
     * Jobs Settings (hierarchy), falling back to the field's default value. Values are inserted as-is, so tokens
     * have the same trust level as the rest of the Sequence Job record, which only admins can edit.
     *
     * @param text The query or parameter text
     *
     * @return The text with tokens replaced; unchanged when it has none
     *
     * @throws JobSequenceException when a token names a field that does not exist or has no value
     */
    public static String apply(String text) {
        if (String.isBlank(text) || !text.contains(TOKEN_START)) {
            return text;
        }
        Map<String, Schema.SObjectField> fields = Sequence_Jobs_Settings__c.SObjectType.getDescribe().fields.getMap();
        Sequence_Jobs_Settings__c settings = Sequence_Jobs_Settings__c.getInstance();
        Sequence_Jobs_Settings__c defaults = (Sequence_Jobs_Settings__c) Sequence_Jobs_Settings__c.SObjectType.newSObject(null, true);

        String result = text;
        Matcher matcher = TOKEN_PATTERN.matcher(text);
        while (matcher.find()) {
            String fieldName = matcher.group(1);
            if (!fields.containsKey(fieldName.toLowerCase())) {
                throw new JobSequenceException('Unknown settings token ' + matcher.group(0) + ': Sequence Jobs Settings has no field ' + fieldName + '.');
            }
            Object value = settings == null ? null : settings.get(fieldName);
            value = value == null ? defaults.get(fieldName) : value;
            if (value == null) {
                throw new JobSequenceException('Settings token ' + matcher.group(0) + ' has no value. Set ' + fieldName + ' in Job Sequencer Settings.');
            }
            result = result.replace(matcher.group(0), format(value));
        }
        System.debug('JobSequenceSettingsTokens()::apply:  result: ' + result);
        return result;
    }

    /**
     * @description Formats a setting value for use in SOQL or a parameter.
     *
     * @param value The value
     *
     * @return The text form: whole numbers without decimals, dates as yyyy-mm-dd, date/times in GMT ISO format
     */
    private static String format(Object value) {
        if (value instanceof Decimal) {
            return ((Decimal) value).stripTrailingZeros().toPlainString();
        }
        if (value instanceof Datetime) {
            return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        }
        if (value instanceof Date) {
            return String.valueOf((Date) value);
        }
        return String.valueOf(value);
    }
}
