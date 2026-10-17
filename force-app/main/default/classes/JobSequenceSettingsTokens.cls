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
