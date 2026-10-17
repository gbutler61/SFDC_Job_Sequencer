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
 * @description: **JobSequenceManagerController** -- Apex controller for the Sequence Jobs tab. Lists Sequence Job
 * records and saves, activates, deactivates and reorders them through Apex metadata deployments; also builds and
 * runs a job's query the way the sequencer does, to test it before saving.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Object and field lists for the query wizard             |
 *   |  10/17/2026 |  Gary Butler      | Handler/function lists; field types for the builder     |
 *   |  10/17/2026 |  Gary Butler      | Typed variables: build, check and test JSON parameters  |
 *   |  10/17/2026 |  Gary Butler      | Run a One Time job standalone                           |
 *
 */
public with sharing class JobSequenceManagerController {
    private static final String TYPE_PREFIX = 'Sequence_Job.';
    private static final Integer TEST_QUERY_SAMPLE_SIZE = 5;
    @TestVisible private static final Integer TEST_QUERY_COUNT_LIMIT = 2000;
    private static final Pattern DEVELOPER_NAME_PATTERN = Pattern.compile('^[A-Za-z][A-Za-z0-9_]{0,39}$');

    //Tests replace this, because Apex tests cannot run metadata deployments
    @TestVisible private static Deployer deployer = new MetadataDeployer();
    //Lets tests supply Sequence Job records, which cannot be inserted in a test
    @TestVisible private static List<Sequence_Job__mdt> recordsOverride;

    /**
     * @description Runs a metadata deployment and returns its Id.
     */
    public interface Deployer {
        /**
         * @description Starts the deployment.
         *
         * @param container The records to deploy
         *
         * @return The deployment Id
         */
        Id deploy(Metadata.DeployContainer container);
    }

    /**
     * @description Deploys through Metadata.Operations, reporting the result with JobSequenceDeployCallback.
     */
    public class MetadataDeployer implements Deployer {
        /**
         * @description Enqueues the deployment.
         *
         * @param container The records to deploy
         *
         * @return The deployment Id
         */
        public Id deploy(Metadata.DeployContainer container) {
            return Metadata.Operations.enqueueDeployment(container, new JobSequenceDeployCallback());
        }
    }

    /**
     * @description One Sequence Job record, as the Sequence Jobs tab shows and edits it.
     */
    public class SequenceJob {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public Boolean active;
        @AuraEnabled public String frequency;
        @AuraEnabled public String order;
        @AuraEnabled public Boolean isBatchJob;
        @AuraEnabled public String jobType;
        @AuraEnabled public String handlerClass;
        @AuraEnabled public String notificationEmail;
        @AuraEnabled public String executionJob;
        @AuraEnabled public Integer batchLimit;
        @AuraEnabled public String upsertExtIdField;
        @AuraEnabled public Boolean permDelete;
        @AuraEnabled public Boolean allOrNone;
        @AuraEnabled public String parameters;
        @AuraEnabled public String selectFields;
        @AuraEnabled public String fromObject;
        @AuraEnabled public String whereClause;
        @AuraEnabled public String orderBy;
        @AuraEnabled public Integer recordLimit;
    }

    /**
     * @description The picklist values the editor offers.
     */
    public class FieldOptions {
        @AuraEnabled public List<String> frequencies;
        @AuraEnabled public List<String> jobTypes;
    }

    /**
     * @description The outcome of running a job's query.
     */
    public class TestQueryResult {
        @AuraEnabled public Boolean isValid;
        @AuraEnabled public String query;
        @AuraEnabled public Integer matchingRows;
        @AuraEnabled public Boolean moreThanLimit;
        @AuraEnabled public Integer countLimit;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String queryHint;
        @AuraEnabled public String orgName;
        @AuraEnabled public Boolean asUnitTest;
        //The query with its {!...} tokens still in it; null when it has none
        @AuraEnabled public String queryWithVariables;
        @AuraEnabled public String queryNote;
    }

    /**
     * @description An object or field the query wizard offers.
     */
    public class SchemaOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String fieldType;
        @AuraEnabled public Boolean sortable;
        //'field', or 'child' for a child relationship (related list), which is inserted as a subquery
        @AuraEnabled public String kind;
        @AuraEnabled public String childObject;
        @AuraEnabled public Boolean updateable;
        @AuraEnabled public List<String> picklistValues;
    }

    /**
     * @description A handler class the editor offers, with the functions it lists (if it implements
     * JobSequenceFunctionCatalog).
     */
    public class HandlerOption {
        @AuraEnabled public String className;
        @AuraEnabled public List<String> functions;
    }

    /**
     * @description Returns every Sequence Job, ordered by frequency and run order.
     *
     * @return The sequence jobs
     */
    @AuraEnabled
    public static List<SequenceJob> getSequenceJobs() {
        List<SequenceJob> jobs = new List<SequenceJob>();
        for (Sequence_Job__mdt sj : querySequenceJobs(null)) {
            jobs.add(toSequenceJob(sj));
        }
        return jobs;
    }

    /**
     * @description Returns the Job Frequency and Job Type picklist values.
     *
     * @return The picklist values
     */
    @AuraEnabled(cacheable=true)
    public static FieldOptions getFieldOptions() {
        FieldOptions options = new FieldOptions();
        options.frequencies = getPicklistValues(Sequence_Job__mdt.Frequency__c);
        options.jobTypes = getPicklistValues(Sequence_Job__mdt.Type__c);
        return options;
    }

    /**
     * @description Validates a Sequence Job and starts saving it. The save finishes asynchronously; its result arrives
     * as a Job Sequencer Deploy Result platform event.
     *
     * @param jobJson The sequence job, serialized as JSON
     * @param isNew   True to create a new record, false to update an existing one
     *
     * @return The deployment Id
     *
     * @throws AuraHandledException when the job is invalid or the deployment cannot be started
     */
    @AuraEnabled
    public static Id saveSequenceJob(String jobJson, Boolean isNew) {
        SequenceJob job = parseJob(jobJson);
        List<String> problems = validate(job, isNew == true);
        if (!problems.isEmpty()) {
            throw newAuraException(String.join(problems, '\n'));
        }
        return deploy(new List<SequenceJob>{job});
    }

    /**
     * @description Activates or deactivates a Sequence Job. Records cannot be deleted from Apex, so deactivating is
     * how a job is retired here.
     *
     * @param developerName The job's API name
     * @param active        True to activate, false to deactivate
     *
     * @return The deployment Id
     *
     * @throws AuraHandledException when the job does not exist or the deployment cannot be started
     */
    @AuraEnabled
    public static Id setActive(String developerName, Boolean active) {
        SequenceJob job = getExistingJob(developerName);
        job.active = active == true;
        return deploy(new List<SequenceJob>{job});
    }

    /**
     * @description Runs one active One Time job on its own, as a tracked Job Sequence Run: no other job in the
     * frequency runs.
     *
     * @param developerName The job's API name
     *
     * @return The Id of the Job Sequence Run
     *
     * @throws AuraHandledException when the job isn't an active One Time job, the sequencer is turned off, or a One
     * Time run is still going
     */
    @AuraEnabled
    public static Id runStandalone(String developerName) {
        JobSequenceRunService.StartResult result = JobSequenceRunService.startStandaloneRun(developerName);
        if (!result.started) {
            throw newAuraException('The job was not started because ' + result.reason);
        }
        System.debug('JobSequenceManagerController()::runStandalone:  runId: ' + result.run.Id);
        return result.run.Id;
    }

    /**
     * @description Moves a Sequence Job one place earlier or later within its frequency by swapping its Order with
     * the neighboring job's.
     *
     * @param developerName The job's API name
     * @param direction     'up' to run earlier, 'down' to run later
     *
     * @return The deployment Id
     *
     * @throws AuraHandledException when the job cannot move that way or the two jobs share the same Order
     */
    @AuraEnabled
    public static Id moveJob(String developerName, String direction) {
        SequenceJob job = getExistingJob(developerName);
        List<SequenceJob> siblings = new List<SequenceJob>();
        for (Sequence_Job__mdt sj : querySequenceJobs(job.frequency)) {
            siblings.add(toSequenceJob(sj));
        }

        Integer index = -1;
        for (Integer i = 0; i < siblings.size(); i++) {
            if (siblings[i].developerName == job.developerName) index = i;
        }
        Integer neighborIndex = direction == 'up' ? index - 1 : index + 1;
        if (index < 0 || neighborIndex < 0 || neighborIndex >= siblings.size()) {
            throw newAuraException(job.label + ' is already ' + (direction == 'up' ? 'first' : 'last') + ' in its frequency.');
        }

        SequenceJob current = siblings[index];
        SequenceJob neighbor = siblings[neighborIndex];
        if (String.isBlank(current.order) || String.isBlank(neighbor.order) || current.order == neighbor.order) {
            throw newAuraException('Give ' + current.label + ' and ' + neighbor.label + ' different Order values first; they can only be swapped when both are set and distinct.');
        }
        String swap = current.order;
        current.order = neighbor.order;
        neighbor.order = swap;
        return deploy(new List<SequenceJob>{current, neighbor});
    }

    /**
     * @description Builds the job's query exactly as the sequencer would, with its tokens resolved (and also returns
     * it as written, with the tokens, when it has any), checks the resolved query runs, and counts the matching rows up
     * to a limit. No record data is returned.
     *
     * @param jobJson     The sequence job, serialized as JSON
     * @param asUnitTest  True to use the variables' test values, as when Test.isRunningTest() is true
     *
     * @return The query, whether it is valid, and the matching row count or the error
     */
    @AuraEnabled
    public static TestQueryResult testQuery(String jobJson, Boolean asUnitTest) {
        SequenceJob job = parseJob(jobJson);
        TestQueryResult result = new TestQueryResult();
        result.countLimit = TEST_QUERY_COUNT_LIMIT;
        result.orgName = UserInfo.getOrganizationName();
        if (String.isBlank(job.fromObject)) {
            result.isValid = false;
            result.errorMessage = 'Enter Query - From first. Queueable jobs only need a query when their function uses one.';
            return result;
        }

        result.asUnitTest = asUnitTest == true;
        try {
            Desymbolized built = desymbolize(job, result.asUnitTest);
            result.query = built.filledIn;
            result.queryWithVariables = built.hasVariables ? built.withVariables : null;
            result.queryNote = built.note;
            String baseQuery = result.query.replaceAll('(?i)\\s+LIMIT\\s+\\d+\\s*$', '');
            Database.query(baseQuery + ' LIMIT ' + TEST_QUERY_SAMPLE_SIZE, AccessLevel.SYSTEM_MODE);

            String countWhere = baseQuery.substringAfter(' FROM ' + job.fromObject + ' WHERE ');
            countWhere = countWhere.contains(' ORDER BY ') ? countWhere.substringBeforeLast(' ORDER BY ') : countWhere;
            String countQuery = 'SELECT COUNT() FROM ' + job.fromObject + ' WHERE ' + countWhere + ' LIMIT ' + (TEST_QUERY_COUNT_LIMIT + 1);
            Integer count = Database.countQuery(countQuery, AccessLevel.SYSTEM_MODE);
            result.moreThanLimit = count > TEST_QUERY_COUNT_LIMIT;
            result.matchingRows = Math.min(count, TEST_QUERY_COUNT_LIMIT);
            result.isValid = true;
            result.queryHint = getParameterHint(job);
        } catch (Exception e) {
            result.isValid = false;
            result.errorMessage = e.getMessage();
            if (e.getMessage().containsIgnoreCase('understand relationship') || e.getMessage().containsIgnoreCase('No such column')) {
                result.queryHint = 'The query is checked against this org (' + result.orgName + '). A field or relationship that exists '
                        + 'in another org may not exist here; for example, RecordType is only available on objects that have record types.';
            } else {
                result.queryHint = getParameterHint(job);
            }
        }
        System.debug('JobSequenceManagerController()::testQuery:  result: ' + result);
        return result;
    }

    /**
     * @description A job's query as written (with variables) and with every variable filled in.
     */
    private class Desymbolized {
        public String withVariables;
        public String filledIn;
        public Boolean hasVariables = false;
        public String note;
    }

    /**
     * @description Builds the job's query for a scheduled run or for when Test.isRunningTest() is true.
     *
     * @param job        The job
     * @param asUnitTest True to use the variables' test values
     *
     * @return The query as written and resolved
     *
     * @throws JobSequenceException when a token cannot be resolved
     */
    private static Desymbolized desymbolize(SequenceJob job, Boolean asUnitTest) {
        Sequence_Job__mdt sj = toRecord(job);
        sj.BatchLimit__c = sj.BatchLimit__c == null ? 200 : sj.BatchLimit__c;
        Desymbolized result = new Desymbolized();
        JobSequence js;
        try {
            JobSequence.useTestParameters = asUnitTest == true;
            js = new JobSequence(sj);
        } finally {
            JobSequence.useTestParameters = null;
        }
        result.withVariables = js.queryTemplate;
        result.filledIn = js.query;
        result.hasVariables = result.withVariables.contains('{!');
        return result;
    }

    /**
     * @description The query a job would build, as written and with its variables filled in, without running it.
     */
    public class BuiltQuery {
        @AuraEnabled public String queryWithVariables;
        @AuraEnabled public String query;
        @AuraEnabled public Boolean asUnitTest;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String note;
        //Parameter problems that stop a save, and warnings
        @AuraEnabled public List<String> problems;
        @AuraEnabled public List<String> warnings;
    }

    /**
     * @description Builds the job's query the way the sequencer would, without running it: as written (with its
     * tokens) and resolved for a scheduled run or a test run, with the parameter problems and warnings.
     *
     * @param jobJson    The sequence job, serialized as JSON
     * @param asUnitTest True to use the variables' test values, as when Test.isRunningTest() is true
     *
     * @return Both versions of the query (queryWithVariables is null when it has no tokens), or the error
     */
    @AuraEnabled
    public static BuiltQuery buildQuery(String jobJson, Boolean asUnitTest) {
        SequenceJob job = parseJob(jobJson);
        BuiltQuery built = new BuiltQuery();
        built.asUnitTest = asUnitTest == true;
        JobSequenceVariables.Issues issues = checkParameters(job);
        built.problems = issues.problems;
        built.warnings = issues.warnings;
        if (String.isBlank(job.fromObject)) {
            return built;
        }
        try {
            Desymbolized query = desymbolize(job, built.asUnitTest);
            built.query = query.filledIn;
            built.queryWithVariables = query.hasVariables ? query.withVariables : null;
            built.note = query.note;
        } catch (Exception e) {
            //A problem already listed isn't repeated as the build error
            built.errorMessage = built.problems.contains(e.getMessage()) ? null : e.getMessage();
        }
        return built;
    }

    /**
     * @description Checks the job's parameters: valid JSON, variable names, types and values, every token in the
     * query resolving in each context the job runs in, and FieldShift's field values naming updateable fields.
     *
     * @param job The job
     *
     * @return The problems (stop the save) and warnings
     */
    @TestVisible
    private static JobSequenceVariables.Issues checkParameters(SequenceJob job) {
        JobSequenceVariables.Issues issues = new JobSequenceVariables.Issues();
        JobSequenceVariables.Definition definition;
        try {
            definition = JobSequenceVariables.parse(job.parameters);
        } catch (JobSequenceException e) {
            issues.problems.add(e.getMessage());
            return issues;
        }
        String queryText = String.join(new List<String>{
            job.selectFields == null ? '' : job.selectFields,
            job.whereClause == null ? '' : job.whereClause,
            job.orderBy == null ? '' : job.orderBy
        }, ' ');
        issues = JobSequenceVariables.check(definition, queryText, job.frequency == 'Test Only');

        Boolean fieldShift = job.jobType == 'Function' && job.executionJob != null && job.executionJob.equalsIgnoreCase('FieldShift');
        if (!fieldShift) {
            if (!definition.fieldValues.isEmpty()) {
                issues.warnings.add('Field values are only used by the FieldShift function; this job ignores them.');
            }
            return issues;
        }
        if (definition.fieldValues.isEmpty()) {
            issues.problems.add('FieldShift needs at least one field value to set.');
            return issues;
        }
        Schema.SObjectType objectType = String.isBlank(job.fromObject) ? null : Schema.getGlobalDescribe().get(job.fromObject.trim());
        Map<String, Schema.SObjectField> fields = objectType == null ? null : objectType.getDescribe().fields.getMap();
        Set<String> seen = new Set<String>();
        for (JobSequenceVariables.FieldValue fv : definition.fieldValues) {
            if (String.isBlank(fv.field)) {
                issues.problems.add('Every field value needs a field.');
            } else if (!seen.add(fv.field.trim().toLowerCase())) {
                issues.problems.add(fv.field + ' is set twice in the field values.');
            } else if (fields != null && (!fields.containsKey(fv.field.trim().toLowerCase())
                    || !fields.get(fv.field.trim().toLowerCase()).getDescribe().isUpdateable())) {
                issues.problems.add(fv.field + ' is not an updateable field on ' + job.fromObject + ', so FieldShift cannot set it.');
            }
        }
        return issues;
    }

    /**
     * @description The parameter problems and warnings, as one hint for Test Query.
     *
     * @param job The job
     *
     * @return The hint, or null when there is nothing to say
     */
    @TestVisible
    private static String getParameterHint(SequenceJob job) {
        JobSequenceVariables.Issues issues = checkParameters(job);
        List<String> messages = new List<String>(issues.problems);
        messages.addAll(issues.warnings);
        return messages.isEmpty() ? null : String.join(messages, ' ');
    }

    /**
     * @description Lists the queryable objects in this org for the query wizard, sorted by label.
     *
     * @return The objects (label and API name)
     */
    @AuraEnabled(cacheable=true)
    public static List<SchemaOption> getObjectOptions() {
        List<SchemaOption> options = new List<SchemaOption>();
        for (Schema.SObjectType objectType : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = objectType.getDescribe(SObjectDescribeOptions.DEFERRED);
            if (!describe.isQueryable() || describe.isDeprecatedAndHidden() || describe.getName().endsWith('__e')) continue;
            SchemaOption option = new SchemaOption();
            option.label = describe.getLabel();
            option.value = describe.getName();
            options.add(option);
        }
        options.sort(new SchemaOptionLabelComparator());
        return options;
    }

    /**
     * @description Lists an object's fields, then its child relationships (related lists), for the query wizard.
     *
     * @param objectName The object API name
     *
     * @return The fields sorted by label, then the child relationships sorted by relationship name
     *
     * @throws AuraHandledException when the object does not exist in this org
     */
    @AuraEnabled(cacheable=true)
    public static List<SchemaOption> getObjectFields(String objectName) {
        Schema.SObjectType objectType = String.isBlank(objectName) ? null : Schema.getGlobalDescribe().get(objectName);
        if (objectType == null) {
            throw newAuraException('There is no object named ' + objectName + ' in this org.');
        }
        List<SchemaOption> options = new List<SchemaOption>();
        for (Schema.SObjectField field : objectType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isDeprecatedAndHidden()) continue;
            SchemaOption option = new SchemaOption();
            option.label = describe.getLabel();
            option.value = describe.getName();
            option.fieldType = String.valueOf(describe.getType());
            option.sortable = describe.isSortable();
            option.updateable = describe.isUpdateable();
            option.kind = 'field';
            if (describe.getType() == Schema.DisplayType.PICKLIST || describe.getType() == Schema.DisplayType.MULTIPICKLIST) {
                option.picklistValues = new List<String>();
                for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
                    if (entry.isActive()) option.picklistValues.add(entry.getValue());
                }
            }
            options.add(option);
        }
        options.sort(new SchemaOptionLabelComparator());

        List<SchemaOption> children = new List<SchemaOption>();
        for (Schema.ChildRelationship relationship : objectType.getDescribe().getChildRelationships()) {
            String relationshipName = relationship.getRelationshipName();
            if (String.isBlank(relationshipName) || relationship.isDeprecatedAndHidden()) continue;
            Schema.DescribeSObjectResult child = relationship.getChildSObject().getDescribe(SObjectDescribeOptions.DEFERRED);
            if (!child.isQueryable()) continue;
            SchemaOption option = new SchemaOption();
            option.label = relationshipName;
            option.value = relationshipName;
            option.kind = 'child';
            option.childObject = child.getName();
            option.sortable = false;
            children.add(option);
        }
        children.sort(new SchemaOptionLabelComparator());
        options.addAll(children);
        return options;
    }

    /**
     * @description Lists the classes that implement JobSequenceInterface, with JobSequenceDefaultHandler first, and the
     * functions each one lists through JobSequenceFunctionCatalog.
     *
     * @return The handler classes
     */
    @AuraEnabled(cacheable=true)
    public static List<HandlerOption> getHandlerOptions() {
        Set<String> classNames = new Set<String>{'JobSequenceDefaultHandler'};
        try {
            for (ApexTypeImplementor implementor : [
                    SELECT ClassName, ClassNamespacePrefix
                    FROM ApexTypeImplementor
                    WHERE InterfaceName = 'JobSequenceInterface' AND IsConcrete = true
                    WITH SYSTEM_MODE
                    ORDER BY ClassName
            ]) {
                classNames.add(String.isBlank(implementor.ClassNamespacePrefix)
                        ? implementor.ClassName
                        : implementor.ClassNamespacePrefix + '.' + implementor.ClassName);
            }
        } catch (Exception e) {
            //The list falls back to the default handler; the class name can still be typed in
            System.debug(LoggingLevel.ERROR, 'JobSequenceManagerController()::getHandlerOptions:  e: ' + e);
        }

        List<HandlerOption> handlers = new List<HandlerOption>();
        for (String className : classNames) {
            HandlerOption handler = new HandlerOption();
            handler.className = className;
            handler.functions = getFunctionNames(className);
            handlers.add(handler);
        }
        return handlers;
    }

    /**
     * @description Reads a handler's function names when it implements JobSequenceFunctionCatalog.
     *
     * @param className The handler class name
     *
     * @return The function names, or an empty list when the handler doesn't list them
     */
    private static List<String> getFunctionNames(String className) {
        try {
            Type handlerType = Type.forName(className);
            Object handler = handlerType == null ? null : handlerType.newInstance();
            if (handler instanceof JobSequenceFunctionCatalog) {
                List<String> names = ((JobSequenceFunctionCatalog) handler).getFunctionNames();
                return names == null ? new List<String>() : names;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'JobSequenceManagerController()::getFunctionNames:  e: ' + e);
        }
        return new List<String>();
    }

    /**
     * @description Sorts schema options by label, then API name.
     */
    private class SchemaOptionLabelComparator implements Comparator<SchemaOption> {
        /**
         * @description Compares two options.
         *
         * @param a The first option
         * @param b The second option
         *
         * @return Negative, zero or positive, as for String.compareTo
         */
        public Integer compare(SchemaOption a, SchemaOption b) {
            Integer byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
            return byLabel != 0 ? byLabel : a.value.compareTo(b.value);
        }
    }

    /**
     * @description Checks a job against the Sequence Job validation rules and naming rules, so problems show before
     * the save is submitted. The platform enforces the validation rules again during the deployment.
     *
     * @param job   The job to check
     * @param isNew True when the job is being created
     *
     * @return The problems found; empty when the job is valid
     */
    @TestVisible
    private static List<String> validate(SequenceJob job, Boolean isNew) {
        List<String> problems = new List<String>();
        Set<String> existingNames = new Set<String>();
        for (Sequence_Job__mdt sj : querySequenceJobs(null)) {
            existingNames.add(sj.DeveloperName.toLowerCase());
        }

        if (String.isBlank(job.developerName) || !DEVELOPER_NAME_PATTERN.matcher(job.developerName).matches()
                || job.developerName.contains('__') || job.developerName.endsWith('_')) {
            problems.add('Sequence Job Name must start with a letter, use only letters, numbers and single underscores, not end with an underscore, and be at most 40 characters.');
        } else if (isNew && existingNames.contains(job.developerName.toLowerCase())) {
            problems.add('A Sequence Job named ' + job.developerName + ' already exists.');
        } else if (!isNew && !existingNames.contains(job.developerName.toLowerCase())) {
            problems.add('No Sequence Job named ' + job.developerName + ' exists.');
        }
        if (String.isBlank(job.label) || job.label.length() > 40) {
            problems.add('Label is required and can be at most 40 characters.');
        }
        if (String.isBlank(job.jobType)) {
            problems.add('Job Type is required.');
        }
        if (String.isBlank(job.executionJob)) {
            problems.add('Job Execution DML Type or Function Name is required.');
        } else if (job.jobType == 'DML' && !new Set<String>{'UPDATE', 'DELETE'}.contains(job.executionJob.toUpperCase())) {
            problems.add('A DML job must use UPDATE or DELETE as its Job Execution DML Type.');
        }
        if (String.isBlank(job.handlerClass)) {
            problems.add('Handler Class is required.');
        } else if (!isValidHandler(job.handlerClass)) {
            problems.add('Handler Class ' + job.handlerClass + ' was not found or does not implement JobSequenceInterface.');
        }
        if (job.batchLimit != null && (job.batchLimit < 1 || job.batchLimit > 200)) {
            problems.add('Job Batch Limit must be from 1 to 200.');
        }
        if (job.isBatchJob == true && (String.isBlank(job.selectFields) || String.isBlank(job.fromObject)
                || String.isBlank(job.whereClause))) {
            problems.add('A batch job needs Query - Select, From and Where.');
        }
        addKeywordProblem(problems, job.selectFields, 'SELECT', 'Query - Select');
        addKeywordProblem(problems, job.fromObject, 'FROM', 'Query - From');
        addKeywordProblem(problems, job.whereClause, 'WHERE', 'Query - Where');
        addKeywordProblem(problems, job.orderBy, 'ORDERBY', 'Query - OrderBy');
        if (String.isNotBlank(job.upsertExtIdField) && job.upsertExtIdField.equalsIgnoreCase('id')) {
            problems.add('Do not use Id as the Upsert External Id Field; Salesforce matches on Id automatically.');
        }
        //Every token must resolve and every value must fit its type, in each context the job runs in
        problems.addAll(checkParameters(job).problems);
        return problems;
    }

    /**
     * @description Checks that a handler class exists and implements JobSequenceInterface, the way JobSequenceExe
     * loads it at run time.
     *
     * @param className The handler class name
     *
     * @return True when the class can be used as a handler
     */
    private static Boolean isValidHandler(String className) {
        try {
            Type handlerType = Type.forName(className);
            return handlerType != null && handlerType.newInstance() instanceof JobSequenceInterface;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Flags a query field that starts with its own keyword (e.g. a Where that begins with WHERE), the way
     * the keyword-check validation rules do.
     *
     * @param problems  The list to add the problem to
     * @param value     The field value
     * @param keyword   The keyword, without spaces
     * @param fieldName The field's label
     */
    private static void addKeywordProblem(List<String> problems, String value, String keyword, String fieldName) {
        if (String.isNotBlank(value) && value.deleteWhitespace().toUpperCase().startsWith(keyword)) {
            problems.add('Do not start ' + fieldName + ' with the ' + keyword.replace('ORDERBY', 'ORDER BY') + ' keyword.');
        }
    }

    /**
     * @description Deploys one or more jobs in a single deployment. Every field is sent, because a custom metadata
     * deployment replaces the whole record.
     *
     * @param jobs The jobs to deploy
     *
     * @return The deployment Id
     *
     * @throws AuraHandledException when the deployment cannot be started
     */
    private static Id deploy(List<SequenceJob> jobs) {
        Metadata.DeployContainer container = new Metadata.DeployContainer();
        for (SequenceJob job : jobs) {
            container.addMetadata(toCustomMetadata(job));
        }
        try {
            Id deploymentId = deployer.deploy(container);
            System.debug('JobSequenceManagerController()::deploy:  deploymentId: ' + deploymentId);
            return deploymentId;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'JobSequenceManagerController()::deploy:  e: ' + e);
            throw newAuraException('The save could not be started: ' + e.getMessage()
                    + ' If this org installed the Job Sequencer package, check that Setup > Apex Settings > "Deploy Metadata from Non-Certified Package Versions via Apex" is enabled.');
        }
    }

    /**
     * @description Builds the custom metadata record to deploy for a job.
     *
     * @param job The job
     *
     * @return The custom metadata record
     */
    @TestVisible
    private static Metadata.CustomMetadata toCustomMetadata(SequenceJob job) {
        Metadata.CustomMetadata record = new Metadata.CustomMetadata();
        record.fullName = TYPE_PREFIX + job.developerName;
        record.label = job.label;
        Map<String, Object> values = new Map<String, Object>{
                'Active__c' => job.active == true,
                'Frequency__c' => job.frequency,
                'Order__c' => job.order,
                'IsBatchJob__c' => job.isBatchJob == true,
                'Type__c' => job.jobType,
                'HandlerClass__c' => job.handlerClass,
                'NotificationEmail__c' => job.notificationEmail,
                'ExecutionJob__c' => job.executionJob,
                'BatchLimit__c' => job.batchLimit,
                'UpsertExtIdField__c' => job.upsertExtIdField,
                'PermDelete__c' => job.permDelete == true,
                'AllOrNone__c' => job.allOrNone == true,
                'Parameters__c' => job.parameters,
                'Select__c' => job.selectFields,
                'From__c' => job.fromObject,
                'Where__c' => job.whereClause,
                'OrderBy__c' => job.orderBy,
                'Limit__c' => job.recordLimit
        };
        for (String field : values.keySet()) {
            Metadata.CustomMetadataValue value = new Metadata.CustomMetadataValue();
            value.field = field;
            value.value = values.get(field);
            record.values.add(value);
        }
        return record;
    }

    /**
     * @description Builds an in-memory Sequence Job record from the editor values, for building its query.
     *
     * @param job The job
     *
     * @return The unsaved record
     */
    private static Sequence_Job__mdt toRecord(SequenceJob job) {
        return new Sequence_Job__mdt(
                Active__c = job.active == true,
                Frequency__c = job.frequency,
                Order__c = job.order,
                IsBatchJob__c = job.isBatchJob == true,
                Type__c = job.jobType,
                HandlerClass__c = job.handlerClass,
                NotificationEmail__c = job.notificationEmail,
                ExecutionJob__c = job.executionJob,
                BatchLimit__c = job.batchLimit,
                UpsertExtIdField__c = job.upsertExtIdField,
                PermDelete__c = job.permDelete == true,
                AllOrNone__c = job.allOrNone == true,
                Parameters__c = job.parameters,
                Select__c = job.selectFields,
                From__c = job.fromObject,
                Where__c = job.whereClause,
                OrderBy__c = job.orderBy,
                Limit__c = job.recordLimit
        );
    }

    /**
     * @description Converts a Sequence Job record to the editor shape.
     *
     * @param sj The record
     *
     * @return The editor values
     */
    private static SequenceJob toSequenceJob(Sequence_Job__mdt sj) {
        SequenceJob job = new SequenceJob();
        job.recordId = sj.Id;
        job.developerName = sj.DeveloperName;
        job.label = sj.MasterLabel;
        job.active = sj.Active__c;
        job.frequency = sj.Frequency__c;
        job.order = sj.Order__c;
        job.isBatchJob = sj.IsBatchJob__c;
        job.jobType = sj.Type__c;
        job.handlerClass = sj.HandlerClass__c;
        job.notificationEmail = sj.NotificationEmail__c;
        job.executionJob = sj.ExecutionJob__c;
        job.batchLimit = sj.BatchLimit__c == null ? null : sj.BatchLimit__c.intValue();
        job.upsertExtIdField = sj.UpsertExtIdField__c;
        job.permDelete = sj.PermDelete__c;
        job.allOrNone = sj.AllOrNone__c;
        job.parameters = sj.Parameters__c;
        job.selectFields = sj.Select__c;
        job.fromObject = sj.From__c;
        job.whereClause = sj.Where__c;
        job.orderBy = sj.OrderBy__c;
        job.recordLimit = sj.Limit__c == null ? null : sj.Limit__c.intValue();
        return job;
    }

    /**
     * @description Queries Sequence Job records with every field, optionally for one frequency, in run order.
     *
     * @param frequency The frequency to limit to, or null for all
     *
     * @return The records
     */
    private static List<Sequence_Job__mdt> querySequenceJobs(String frequency) {
        if (recordsOverride != null) {
            List<Sequence_Job__mdt> matches = new List<Sequence_Job__mdt>();
            for (Sequence_Job__mdt sj : recordsOverride) {
                if (frequency == null || sj.Frequency__c == frequency) matches.add(sj);
            }
            return matches;
        }
        String query = 'SELECT Id, DeveloperName, MasterLabel, Active__c, Frequency__c, Order__c, IsBatchJob__c, Type__c, '
                + 'HandlerClass__c, NotificationEmail__c, ExecutionJob__c, BatchLimit__c, UpsertExtIdField__c, PermDelete__c, '
                + 'AllOrNone__c, Parameters__c, Select__c, From__c, Where__c, OrderBy__c, Limit__c FROM Sequence_Job__mdt';
        if (frequency != null) {
            query += ' WHERE Frequency__c = :frequency';
        }
        query += ' ORDER BY Frequency__c, Order__c, MasterLabel';
        return Database.queryWithBinds(query, new Map<String, Object>{'frequency' => frequency}, AccessLevel.SYSTEM_MODE);
    }

    /**
     * @description Loads an existing job.
     *
     * @param developerName The job's API name
     *
     * @return The job
     *
     * @throws AuraHandledException when the job does not exist
     */
    private static SequenceJob getExistingJob(String developerName) {
        if (String.isNotBlank(developerName)) {
            for (Sequence_Job__mdt sj : querySequenceJobs(null)) {
                if (sj.DeveloperName.equalsIgnoreCase(developerName)) return toSequenceJob(sj);
            }
        }
        throw newAuraException('No Sequence Job named ' + developerName + ' exists.');
    }

    /**
     * @description Reads a job sent from the editor.
     *
     * @param jobJson The job, serialized as JSON
     *
     * @return The job
     *
     * @throws AuraHandledException when the JSON cannot be read
     */
    private static SequenceJob parseJob(String jobJson) {
        try {
            return (SequenceJob) JSON.deserialize(jobJson, SequenceJob.class);
        } catch (Exception e) {
            throw newAuraException('The sequence job could not be read: ' + e.getMessage());
        }
    }

    /**
     * @description Returns the active values of a picklist field.
     *
     * @param field The picklist field
     *
     * @return The values, in definition order
     */
    private static List<String> getPicklistValues(Schema.SObjectField field) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) values.add(entry.getValue());
        }
        return values;
    }

    /**
     * @description Builds an AuraHandledException whose message is readable both in the LWC and in Apex tests.
     *
     * @param message The message to show the user
     *
     * @return The exception, ready to throw
     */
    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
