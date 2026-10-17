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
 * @description: **JobSequenceVariables** -- Reads a Sequence Job's Job Parameters (JSON: field values, typed variables
 * and handler parameters) and resolves the tokens in its query and values: {!Var.name}, {!Settings.Field__c},
 * {!Label.Name}, {!Mdt.Type__mdt.Record.Field__c}, {!Now}, {!Today} and {!UserId}. Variables become SOQL literals of
 * their type, so a query never needs a bind variable; each variable may have a separate value for when
 * Test.isRunningTest() is true.
 * @author: Gary Butler
 * @date: 10/17/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/17/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
public without sharing class JobSequenceVariables {
    public static final List<String> TYPES = new List<String>{
        'Text', 'Number', 'Boolean', 'Date', 'DateTime', 'RelativeDate', 'RelativeDateTime', 'TextList', 'SoqlFragment'
    };
    private static final Pattern TOKEN_PATTERN = Pattern.compile('\\{!\\s*([A-Za-z]+)(?:\\.([A-Za-z0-9_.]+))?\\s*\\}');
    private static final Pattern NAME_PATTERN = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,39}$');
    private static final Pattern RELATIVE_PATTERN = Pattern.compile('(?i)^\\s*([+-]?\\d+)\\s*(minute|hour|day|week|month|year)s?\\s*$');
    private static final Pattern IDENTIFIER_PATTERN = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');
    private static final String SOQL_DATETIME = 'yyyy-MM-dd\'T\'HH:mm:ss\'Z\'';
    //The form JobSequenceUtilities.changeSobjectValueFromParameters reads for date/time fields
    private static final String VALUE_DATETIME = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';

    /**
     * @description The Job Parameters of one Sequence Job.
     */
    public class Definition {
        public Integer version;
        public List<FieldValue> fieldValues;
        public List<Variable> variables;
        public Map<String, String> handlerParameters;
    }

    /**
     * @description A value FieldShift sets on every record the query returns.
     */
    public class FieldValue {
        public String field;
        public String value;
        //True to clear the field; value is ignored
        public Boolean blank;
    }

    /**
     * @description A named, typed value used in the query as {!Var.name}.
     */
    public class Variable {
        public String name;
        public String type;
        public String value;
        //Used instead of value when Test.isRunningTest() is true; blank means use value
        public String testValue;
    }

    /**
     * @description What is wrong with a job's parameters: problems stop the save, warnings are shown only.
     */
    public class Issues {
        public List<String> problems = new List<String>();
        public List<String> warnings = new List<String>();
    }

    /**
     * @description Reads Job Parameters JSON. Blank parameters give an empty definition.
     *
     * @param text The Job Parameters field
     *
     * @return The definition, with empty lists and map in place of missing ones
     *
     * @throws JobSequenceException when the text is not Job Parameters JSON
     */
    public static Definition parse(String text) {
        Definition definition;
        if (String.isBlank(text)) {
            definition = new Definition();
        } else if (!text.trim().startsWith('{')) {
            throw new JobSequenceException('Job Parameters must be JSON, e.g. {"variables": [...]}. Open the job on the '
                    + 'Sequence Jobs tab to build them.');
        } else {
            try {
                definition = (Definition) JSON.deserialize(text, Definition.class);
            } catch (JSONException e) {
                throw new JobSequenceException('Job Parameters are not valid JSON: ' + e.getMessage());
            }
        }
        definition.version = definition.version == null ? 1 : definition.version;
        definition.fieldValues = definition.fieldValues == null ? new List<FieldValue>() : definition.fieldValues;
        definition.variables = definition.variables == null ? new List<Variable>() : definition.variables;
        definition.handlerParameters = definition.handlerParameters == null ? new Map<String, String>() : definition.handlerParameters;
        return definition;
    }

    /**
     * @description Resolves tokens for one run context: a scheduled run, or Test.isRunningTest() true. The current
     * time is read once, so every relative value in a run is measured from the same moment.
     */
    public class Resolver {
        private Map<String, Variable> variablesByName = new Map<String, Variable>();
        private Boolean inTest;
        private Datetime now = Datetime.now();
        public Set<String> usedVariables = new Set<String>();

        /**
         * @description Creates a resolver for a job's variables.
         *
         * @param definition The job's parameters
         * @param inTest     True to use each variable's test value when it has one
         */
        public Resolver(Definition definition, Boolean inTest) {
            this.inTest = inTest == true;
            for (Variable v : definition.variables) {
                if (String.isNotBlank(v.name)) variablesByName.put(v.name.toLowerCase(), v);
            }
        }

        /**
         * @description Replaces the tokens in a query with SOQL literals: text is quoted and escaped, lists become
         * ('a','b'), dates and date/times are formatted for SOQL. Settings, label and custom metadata values are
         * inserted as written.
         *
         * @param text The query or query part
         *
         * @return The query with every token replaced
         *
         * @throws JobSequenceException when a token is unknown or a variable has no valid value
         */
        public String resolveQuery(String text) {
            return resolve(text, true);
        }

        /**
         * @description Replaces the tokens in a field value or handler parameter with plain values (no quotes).
         *
         * @param text The value
         *
         * @return The value with every token replaced
         *
         * @throws JobSequenceException when a token is unknown or a variable has no valid value
         */
        public String resolveValue(String text) {
            return resolve(text, false);
        }

        /**
         * @description Formats one variable's value for the run context.
         *
         * @param v    The variable
         * @param soql True for a SOQL literal, false for a plain value
         *
         * @return The formatted value
         *
         * @throws JobSequenceException when the variable has no value or the value doesn't fit its type
         */
        public String format(Variable v, Boolean soql) {
            String type = canonicalType(v.type);
            if (type == null) {
                throw new JobSequenceException('Variable ' + v.name + ' has an unknown type "' + v.type + '". Use one of: ' + String.join(TYPES, ', ') + '.');
            }
            Boolean useTest = inTest && String.isNotBlank(v.testValue);
            String raw = useTest ? v.testValue : v.value;
            if (type == 'SoqlFragment') {
                return raw == null ? '' : raw;
            }
            if (String.isBlank(raw)) {
                throw new JobSequenceException('Variable ' + v.name + ' has no value' + (inTest ? '' : ' for scheduled runs')
                        + '. Set its Value' + (inTest ? ' or Test value' : '') + ' in Job Parameters.');
            }
            String context = 'Variable ' + v.name + (useTest ? ' (test value)' : '');
            raw = raw.trim();
            switch on type {
                when 'Text' {
                    return soql ? quote(raw) : raw;
                }
                when 'Number' {
                    try {
                        return Decimal.valueOf(raw).stripTrailingZeros().toPlainString();
                    } catch (TypeException e) {
                        throw new JobSequenceException(context + ' must be a number, not "' + raw + '".');
                    }
                }
                when 'Boolean' {
                    if (!raw.equalsIgnoreCase('true') && !raw.equalsIgnoreCase('false')) {
                        throw new JobSequenceException(context + ' must be true or false, not "' + raw + '".');
                    }
                    return raw.toLowerCase();
                }
                when 'Date' {
                    return String.valueOf(parseDate(raw, context));
                }
                when 'DateTime' {
                    return parseDatetime(raw, context).formatGmt(soql ? SOQL_DATETIME : VALUE_DATETIME);
                }
                when 'RelativeDate' {
                    return String.valueOf(relativeDate(raw, context));
                }
                when 'RelativeDateTime' {
                    return relativeDatetime(raw, context).formatGmt(soql ? SOQL_DATETIME : VALUE_DATETIME);
                }
                when else {
                    //TextList
                    List<String> items = new List<String>();
                    for (String item : raw.split(',')) {
                        if (String.isNotBlank(item)) items.add(soql ? quote(item.trim()) : item.trim());
                    }
                    if (items.isEmpty()) {
                        throw new JobSequenceException(context + ' needs at least one item, e.g. A, B.');
                    }
                    return soql ? '(' + String.join(items, ',') + ')' : String.join(items, ',');
                }
            }
        }

        /**
         * @description Replaces settings tokens, then every other token in the text.
         *
         * @param text The text
         * @param soql True to format variables as SOQL literals
         *
         * @return The text with every token replaced
         */
        private String resolve(String text, Boolean soql) {
            if (String.isBlank(text)) {
                return text;
            }
            String result = JobSequenceSettingsTokens.apply(text);
            if (!result.contains('{!')) {
                return result;
            }
            Matcher matcher = TOKEN_PATTERN.matcher(result);
            String output = '';
            Integer last = 0;
            while (matcher.find()) {
                output += literalText(result.substring(last, matcher.start())) + resolveToken(matcher.group(0), matcher.group(1), matcher.group(2), soql);
                last = matcher.end();
            }
            output += literalText(result.substring(last));
            System.debug('JobSequenceVariables()::resolve:  output: ' + output);
            return output;
        }

        /**
         * @description Checks text between tokens has no malformed token left in it, such as {!Label.Bad-Name}.
         *
         * @param text The text between two tokens
         *
         * @return The text, unchanged
         *
         * @throws JobSequenceException when it contains {! that is not a valid token
         */
        private String literalText(String text) {
            if (text.contains('{!')) {
                String snippet = text.substring(text.indexOf('{!'));
                throw new JobSequenceException('Unknown token ' + (snippet.contains('}') ? snippet.substringBefore('}') + '}' : snippet)
                        + '. Use {!Var.name}, {!Settings.Field__c}, {!Label.Name}, {!Mdt.Type__mdt.Record.Field__c}, {!Now}, {!Today} or {!UserId}.');
            }
            return text;
        }

        /**
         * @description Resolves one token.
         *
         * @param token  The whole token, for messages
         * @param source The part after {! (Var, Label, Mdt, Now, Today, UserId)
         * @param path   The part after the first dot, or null
         * @param soql   True to format variables as SOQL literals
         *
         * @return The token's value
         *
         * @throws JobSequenceException when the token is unknown or names something that does not exist
         */
        private String resolveToken(String token, String source, String path, Boolean soql) {
            switch on source.toLowerCase() {
                when 'var' {
                    Variable v = path == null ? null : variablesByName.get(path.toLowerCase());
                    if (v == null) {
                        throw new JobSequenceException(token + ' is used, but no variable named ' + path + ' is defined in Job Parameters.');
                    }
                    usedVariables.add(v.name.toLowerCase());
                    return format(v, soql);
                }
                when 'label' {
                    return labelValue(token, path);
                }
                when 'mdt' {
                    return metadataValue(token, path);
                }
                when 'now' {
                    return now.formatGmt(soql ? SOQL_DATETIME : VALUE_DATETIME);
                }
                when 'today' {
                    return String.valueOf(now.dateGmt());
                }
                when 'userid' {
                    return soql ? quote(UserInfo.getUserId()) : UserInfo.getUserId();
                }
                when else {
                    throw new JobSequenceException('Unknown token ' + token + '. Use {!Var.name}, {!Settings.Field__c}, {!Label.Name}, '
                            + '{!Mdt.Type__mdt.Record.Field__c}, {!Now}, {!Today} or {!UserId}.');
                }
            }
        }

        /**
         * @description Turns an amount like -90 days into a date, counted from today (GMT).
         *
         * @param raw     The amount and unit
         * @param context The variable, for messages
         *
         * @return The date
         *
         * @throws JobSequenceException when the value is not days, weeks, months or years
         */
        private Date relativeDate(String raw, String context) {
            Matcher m = RELATIVE_PATTERN.matcher(raw);
            if (!m.matches() || new Set<String>{'minute', 'hour'}.contains(m.group(2).toLowerCase())) {
                throw new JobSequenceException(context + ' must be a whole number of days, weeks, months or years, e.g. -90 days, not "' + raw + '".');
            }
            Integer amount = Integer.valueOf(m.group(1).replace('+', ''));
            Date today = now.dateGmt();
            switch on m.group(2).toLowerCase() {
                when 'day' { return today.addDays(amount); }
                when 'week' { return today.addDays(amount * 7); }
                when 'month' { return today.addMonths(amount); }
                when else { return today.addYears(amount); }
            }
        }

        /**
         * @description Turns an amount like -2 hours into a date/time, counted from now.
         *
         * @param raw     The amount and unit
         * @param context The variable, for messages
         *
         * @return The date/time
         *
         * @throws JobSequenceException when the value is not an amount and unit
         */
        private Datetime relativeDatetime(String raw, String context) {
            Matcher m = RELATIVE_PATTERN.matcher(raw);
            if (!m.matches()) {
                throw new JobSequenceException(context + ' must be a whole number of minutes, hours, days, weeks, months or years, e.g. -2 hours, not "' + raw + '".');
            }
            Integer amount = Integer.valueOf(m.group(1).replace('+', ''));
            switch on m.group(2).toLowerCase() {
                when 'minute' { return now.addMinutes(amount); }
                when 'hour' { return now.addHours(amount); }
                when 'day' { return now.addDays(amount); }
                when 'week' { return now.addDays(amount * 7); }
                when 'month' { return now.addMonths(amount); }
                when else { return now.addYears(amount); }
            }
        }
    }

    /**
     * @description Checks a job's parameters and query: variable names, types and values for both run contexts,
     * that every token resolves, and that every variable is used.
     *
     * @param definition The job's parameters
     * @param queryText  The query as written, with its tokens
     * @param testOnly   True for a Test Only job, which never has a scheduled run
     *
     * @return The problems (stop the save) and warnings
     */
    public static Issues check(Definition definition, String queryText, Boolean testOnly) {
        Issues issues = new Issues();
        Set<String> names = new Set<String>();
        for (Variable v : definition.variables) {
            if (String.isBlank(v.name) || !NAME_PATTERN.matcher(v.name).matches()) {
                issues.problems.add('Variable name "' + (v.name == null ? '' : v.name) + '" must start with a letter and use only letters, numbers and underscores.');
            } else if (!names.add(v.name.toLowerCase())) {
                issues.problems.add('Two variables are named ' + v.name + '.');
            }
            if (canonicalType(v.type) == null) {
                issues.problems.add('Variable ' + v.name + ' needs a type: ' + String.join(TYPES, ', ') + '.');
            }
        }
        Set<String> handlerNames = new Set<String>();
        for (String key : definition.handlerParameters.keySet()) {
            if (String.isBlank(key)) issues.problems.add('Every handler parameter needs a name.');
            else if (!handlerNames.add(key.toLowerCase())) issues.problems.add('Two handler parameters are named ' + key + '.');
        }
        if (!issues.problems.isEmpty()) {
            return issues;
        }

        //Resolving everything in each context finds unknown tokens and values that don't fit their type
        Set<String> used = new Set<String>();
        List<Boolean> contexts = testOnly == true ? new List<Boolean>{true} : new List<Boolean>{false, true};
        for (Boolean inTest : contexts) {
            Resolver resolver = new Resolver(definition, inTest);
            String context = inTest ? ' (when Test.isRunningTest() is true)' : '';
            try {
                resolver.resolveQuery(queryText);
                for (FieldValue fv : definition.fieldValues) {
                    if (fv.blank != true) resolver.resolveValue(fv.value);
                }
                for (String value : definition.handlerParameters.values()) {
                    resolver.resolveValue(value);
                }
                for (Variable v : definition.variables) {
                    resolver.format(v, true);
                }
            } catch (JobSequenceException e) {
                String message = e.getMessage() + context;
                if (!issues.problems.contains(message)) issues.problems.add(message);
            }
            used.addAll(resolver.usedVariables);
        }
        for (Variable v : definition.variables) {
            if (!used.contains(v.name.toLowerCase())) {
                issues.warnings.add('Variable ' + v.name + ' is defined but never used. Insert {!Var.' + v.name + '} where it belongs.');
            }
        }
        return issues;
    }

    /**
     * @description The type name as listed in TYPES, matched without regard to case.
     *
     * @param type The type as written
     *
     * @return The canonical type, or null when it isn't one
     */
    private static String canonicalType(String type) {
        if (String.isBlank(type)) {
            return null;
        }
        for (String t : TYPES) {
            if (t.equalsIgnoreCase(type.trim())) return t;
        }
        return null;
    }

    /**
     * @description Quotes and escapes a SOQL string literal.
     *
     * @param value The text
     *
     * @return The literal
     */
    private static String quote(String value) {
        return '\'' + String.escapeSingleQuotes(value) + '\'';
    }

    /**
     * @description Reads a date like 2026-10-17.
     *
     * @param raw     The value
     * @param context The variable, for messages
     *
     * @return The date
     *
     * @throws JobSequenceException when it is not a date
     */
    private static Date parseDate(String raw, String context) {
        try {
            return Date.valueOf(raw);
        } catch (Exception e) {
            throw new JobSequenceException(context + ' must be a date like 2026-10-17, not "' + raw + '".');
        }
    }

    /**
     * @description Reads an ISO 8601 date/time like 2026-10-17T15:00:00Z.
     *
     * @param raw     The value
     * @param context The variable, for messages
     *
     * @return The date/time
     *
     * @throws JobSequenceException when it is not a date/time
     */
    private static Datetime parseDatetime(String raw, String context) {
        try {
            return (Datetime) JSON.deserialize('"' + raw + '"', Datetime.class);
        } catch (Exception e) {
            throw new JobSequenceException(context + ' must be a date/time like 2026-10-17T15:00:00Z, not "' + raw + '".');
        }
    }

    /**
     * @description The value of a custom label, in the running user's language.
     *
     * @param token The whole token, for messages
     * @param path  The label name
     *
     * @return The label text
     *
     * @throws JobSequenceException when no such label exists
     */
    private static String labelValue(String token, String path) {
        if (path == null || !IDENTIFIER_PATTERN.matcher(path).matches()) {
            throw new JobSequenceException(token + ' must name a custom label, e.g. {!Label.My_Label}.');
        }
        try {
            return System.Label.get('', path);
        } catch (Exception e) {
            throw new JobSequenceException(token + ': no custom label named ' + path + ' exists.');
        }
    }

    /**
     * @description A field value from a custom metadata record.
     *
     * @param token The whole token, for messages
     * @param path  Type__mdt.Record.Field__c
     *
     * @return The value as text
     *
     * @throws JobSequenceException when the type, record or field does not exist or the value is blank
     */
    private static String metadataValue(String token, String path) {
        List<String> parts = path == null ? new List<String>() : path.split('\\.');
        if (parts.size() != 3 || !parts[0].endsWithIgnoreCase('__mdt')) {
            throw new JobSequenceException(token + ' must be {!Mdt.Type__mdt.Record.Field__c}.');
        }
        for (String part : parts) {
            if (!IDENTIFIER_PATTERN.matcher(part).matches()) {
                throw new JobSequenceException(token + ' must be {!Mdt.Type__mdt.Record.Field__c}.');
            }
        }
        List<SObject> records;
        try {
            records = Database.queryWithBinds(
                'SELECT ' + parts[2] + ' FROM ' + parts[0] + ' WHERE DeveloperName = :recordName LIMIT 1',
                new Map<String, Object>{'recordName' => parts[1]},
                AccessLevel.SYSTEM_MODE
            );
        } catch (QueryException e) {
            throw new JobSequenceException(token + ': ' + e.getMessage());
        }
        if (records.isEmpty()) {
            throw new JobSequenceException(token + ': ' + parts[0] + ' has no record named ' + parts[1] + '.');
        }
        Object value = records[0].get(parts[2]);
        if (value == null) {
            throw new JobSequenceException(token + ' has no value.');
        }
        if (value instanceof Decimal) return ((Decimal) value).stripTrailingZeros().toPlainString();
        if (value instanceof Datetime) return ((Datetime) value).formatGmt(SOQL_DATETIME);
        return String.valueOf(value);
    }
}
