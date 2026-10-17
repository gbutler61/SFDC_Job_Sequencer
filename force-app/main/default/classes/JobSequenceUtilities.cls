/**
 * Copyright 2019 Jason Hardy
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
 * @description: **JobSequenceUtilities** -- This class contains various utility methods which can be used by the job sequence functionality
 * @author: Jason Hardy
 * @date: 10/26/2019
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/26/2019 |  Jason Hardy      | Initial Creation (original author)                      |
 *   |  10/16/2026 |  Gary Butler      | Fork: Select/Where/Params LongTextArea for complex SOQL |
 *   |  10/16/2026 |  Gary Butler      | Added ApexDoc comments                                  |
 *   |  10/16/2026 |  Gary Butler      | API 68.0; explicit system mode on SOQL/DML              |
 *   |  10/16/2026 |  Gary Butler      | Fix: check CronTrigger for existing scheduled run       |
 *   |  10/16/2026 |  Gary Butler      | Count DML failures; link errors to their run            |
 *   |  10/17/2026 |  Gary Butler      | Debug label format                                      |
 *   |  10/17/2026 |  Gary Butler      | Schedule methods use the Scheduler (old classes gone)   |
 *   |  10/17/2026 |  Gary Butler      | Doc: field values come from the JSON Job Parameters     |
 *
 */
global without sharing class JobSequenceUtilities {
    private static final Set<String> DECIMAL_TYPES = new Set<String>{'DOUBLE','PERCENT','CURRENCY'};
    private static Set<String> FIELD_TYPES_TO_CAST = new Set<String> {'DATE','DATETIME','INTEGER','BOOLEAN','DOUBLE','PERCENT','CURRENCY'};
    //Rows that failed in partial-success DML since JobSequenceExe last reset it; read for run metrics
    public static Integer dmlFailureCount = 0;
    //The job sequence JobSequenceExe is running, so errors logged without one are still tied to it and its run
    public static JobSequence currentJobSequence;

    /**
     * @description This method perform the DML operation specified to the records passed.
     *
     * This is different from the normal attempt DML because it will not be executed in a try catch, this way the
     * error log can be initiated from the job sequence handler
     *
     * @param records       The records to be adjusted
     * @param operationType The operation to be executed (Insert, Update, Delete and Upsert)
     * @param allOrNone     Whether or not it should allow partial success or fail the entire batch.
     *
     * @return              The updated records
     */
    global static List<SObject> attemptJobSequenceDML(List<SObject> records, String operationType, Boolean allOrNone) {
        return attemptJobSequenceDML(records,operationType,null,allOrNone,false);
    }

    /**
     * @description This method perform the DML operation specified to the records passed.
     *
     * This is different from the normal attempt DML because it will not be executed in a try catch, this way the
     * error log can be initiated from the job sequence handler
     *
     * @param records       The records to be adjusted
     * @param operationType The operation to be executed (Insert, Update, Delete and Upsert)
     * @param extIdField    The API name of the external Id field to be upserted against
     * @param allOrNone     Whether or not it should allow partial success or fail the entire batch.
     * @param permDelete    Whether or not the recycle bin should be purged after the delete operation takes place
     *
     * @return              The updated records
     */
    global static List<SObject> attemptJobSequenceDML(
            List<SObject> records,
            String operationType,
            String extIdField,
            Boolean allOrNone,
            Boolean permDelete
    ) {
        if (records != null && !records.isEmpty()) {
            try {
                switch on operationType.toUpperCase() {
                    when 'INSERT' { countFailures(Database.insert(records,allOrNone,AccessLevel.SYSTEM_MODE));}
                    when 'UPDATE' { countFailures(Database.update(records,allOrNone,AccessLevel.SYSTEM_MODE));}
                    when 'DELETE' { handleDynamicDeletes(records,allOrNone,permDelete);}
                    when 'UPSERT' { handleDynamicUpsert(records,extIdField);}
                    when else {
                        throw new JobSequenceException('Could not preform the requested operation: '+operationType);
                    }
                }
            } catch (Exception e) {
                dmlFailureCount += records.size();
                logError(null,records,e);
            }
        }

        return records;
    }

    /**
     * @description Updates field values on the SObject from the parameter map, casting each value to the
     * field's type. FieldShift passes the field values from the Job Parameters (JobSequence.fieldValuesByField),
     * keyed by lower-case field API name; the value 'null' clears the field.
     *
     * @param sobj      The sobject that will be changed
     * @param fldMap    The field map for the sobject's type
     * @param params    The parameters containing the field API name and the new value
     *
     * @return          The adjusted sobject
     *
     * @throws JobSequenceException when a parameter names a field that cannot be described
     */
    global static SObject changeSobjectValueFromParameters(
            SObject sobj,
            Map<String,Schema.SObjectField> fldMap,
            Map<String,String> params
    ) {
        //Going through each of the fields defined in the parameter map and swapping the value as needed
        for (String fldNm : params.keySet()) {
            if (fldMap.containsKey(fldNm)) {
                Schema.DescribeFieldResult field = fldMap.get(fldNm).getDescribe();
                if (field != null) {
                    Object val = params.get(fldNm);
                    String strVal = String.valueOf(val);
                    val = String.isNotBlank(strVal) && strVal.equalsIgnoreCase('null') ? null : val;

                    String fldType = String.valueOf(field.getType());

                    //If the value is not null, need to cast the value of the field appropriately if needed
                    if (val != null && fldType != null && FIELD_TYPES_TO_CAST.contains(fldType)) {
                        if (fldType == 'DATE') val = Date.valueOf(strVal);
                        if (fldType == 'DATETIME') val = Datetime.valueOfGmt(strVal.replace('T',' ').left(strVal.length()-5));
                        if (fldType == 'INTEGER') val = Integer.valueOf(strVal);
                        if (fldType == 'BOOLEAN') val = Boolean.valueOf(strVal);
                        if (DECIMAL_TYPES.contains(fldType)) val = Decimal.valueOf(strVal);
                    }

                    sobj.put(fldNm, val);
                }
                if (field == null) throw new JobSequenceException(fldNm+' is not a valid field!');
            }
        }
        return sobj;
    }

    /**
     * @description Will execute dynamic sobject deletes
     *
     * @param records       The records to be deleted
     * @param allOrNone     Whether or not it should allow partial success or fail the entire batch.
     * @param permDelete    If this option is selected the records will be removed from the recycle bin
     */
    global static void handleDynamicDeletes(List<SObject> records, Boolean allOrNone, Boolean permDelete) {
        allOrNone = allOrNone == null ? false : allOrNone;
        permDelete = permDelete == null ? false : permDelete;
        countFailures(Database.delete(records,allOrNone,AccessLevel.SYSTEM_MODE));
        if (permDelete != null && permDelete) Database.emptyRecycleBin(new List<Id> (new Map<Id,SObject>(records).keySet()));
    }


    /**
     * @description Will execute a dynamic sobject upsert using the set of records passed as well as the other options
     *
     * Note, specifying an external Id field will negate the all or none setting
     *
     * @param records       The records to be upsert
     * @param extIdField    The external id to be used to upsert against. If a field is passed, all or none is negated!
     *
     * @return              The list of dynamically upserted records
     */
    global static List<SObject> handleDynamicUpsert(List<SObject> records, String extIdField) {
        Schema.DescribeSObjectResult sobjType = records[0].getSObjectType().getDescribe();
        if (sobjType != null) {
            String listType = 'List<' + sobjType.getName() + '>';
            Schema.SObjectField extId = sobjType.fields.getMap().containsKey(extIdField) ?
                    sobjType.fields.getMap().get(extIdField) : null;
            List<SObject> castRecords = (List<SObject>) Type.forName(listType).newInstance();
            castRecords.addAll(records);
            List<Database.UpsertResult> results;
            if (extId == null) results = Database.upsert(castRecords, true, AccessLevel.SYSTEM_MODE);
            if (extId != null) results = Database.upsert(castRecords, extId, true, AccessLevel.SYSTEM_MODE);
            countFailures(results);

            records = castRecords;
        }

        return records;
    }

    /**
     * @description Method will log an error in the Job Sequence error object
     *
     * @param js    The job sequence object wrapper
     * @param scope The scope of records being worked with
     * @param e     The exception
     */
    global static void logError(JobSequence js, List<SObject> scope, Exception e) {
        JobSequence target = js != null ? js : currentJobSequence;
        if (target != null) target.errorsLogged++;
        Id jobId = target == null ? null : target.jobId;
        String jobName = target == null ? 'Unknown' : target.currentJob;
        String frequency = target == null ? 'Unknown' : target.jobFrequency;
        Set<Id> ids = scope == null ? null : new Map<Id,SObject>(scope).keySet();
        logError(jobId, jobName, frequency, e, ids, target == null ? null : target.runId);
    }

    /**
     * @description Method will log an error in the Job Sequence error object
     *
     * @param jobId         The job Id to log against
     * @param currentJob    The name of the current job
     * @param jobFrequency  The frequency of hte current job
     * @param e             The exception
     * @param idScope       The ids that failed
     */
    global static void logError(Id jobId, String currentJob, String jobFrequency, Exception e, Set<Id> idScope) {
        logError(jobId, currentJob, jobFrequency, e, idScope, null);
    }

    /**
     * @description Logs an error in the Job Sequence Error object, linked to the Job Sequence Run it happened in
     *
     * @param jobId         The job Id to log against
     * @param currentJob    The name of the current job
     * @param jobFrequency  The frequency of the current job
     * @param e             The exception
     * @param idScope       The ids that failed
     * @param runId         The Job Sequence Run, or null when unknown
     */
    public static void logError(Id jobId, String currentJob, String jobFrequency, Exception e, Set<Id> idScope, Id runId) {
        String exceptionText = String.format(
                Label.Job_Sequence_Exception_Template,
                new List<String> {
                        String.valueOf(e.getCause()),
                        String.valueOf(e.getLineNumber()),
                        String.valueOf(e.getMessage()),
                        String.valueOf(e.getStackTraceString())
                }
        );

        Job_Sequence_Error__c jse = new Job_Sequence_Error__c(
                BatchJobId__c=jobId,
                Exception__c = exceptionText,
                Scope__c = idScope != null ? String.valueOf(idScope) : 'None',
                JobName__c = currentJob,
                JobFrequency__c = jobFrequency,
                Run__c = runId
        );
        insert as system jse;
    }

    /**
     * @description Schedules all of the out of the box job sequence runs.
     */
    global static void scheduleAllRuns() {
        scheduleHourlyRun();
        scheduleDailyRun();
        scheduleWeeklyRun();
        scheduleMonthlyRun();
        scheduleQuarterlyRun();
        scheduleYearlyRun();
    }

    /**
     * @description Schedules the Hourly frequency the way the Job Sequence Scheduler tab does; does nothing when it
     * is already scheduled.
     */
    global static void scheduleHourlyRun() {
        scheduleFrequency('Hourly');
    }

    /**
     * @description Schedules the Daily frequency the way the Job Sequence Scheduler tab does; does nothing when it
     * is already scheduled.
     */
    global static void scheduleDailyRun() {
        scheduleFrequency('Daily');
    }

    /**
     * @description Schedules the Weekly frequency the way the Job Sequence Scheduler tab does; does nothing when it
     * is already scheduled.
     */
    global static void scheduleWeeklyRun() {
        scheduleFrequency('Weekly');
    }
    
    /**
     * @description Schedules the Monthly frequency the way the Job Sequence Scheduler tab does; does nothing when it
     * is already scheduled.
     */
    global static void scheduleMonthlyRun() {
        scheduleFrequency('Monthly');
    }

    /**
     * @description Schedules the Quarterly frequency the way the Job Sequence Scheduler tab does; does nothing when it
     * is already scheduled.
     */
    global static void scheduleQuarterlyRun() {
        scheduleFrequency('Quarterly');
    }

    /**
     * @description Schedules the Yearly frequency the way the Job Sequence Scheduler tab does; does nothing when it
     * is already scheduled.
     */
    global static void scheduleYearlyRun() {
        scheduleFrequency('Yearly');
    }

    /**
     * @description Schedules a frequency with the Scheduler's single scheduled-run class. A frequency that is already
     * scheduled is left as it is.
     *
     * @param frequency The frequency to schedule
     */
    private static void scheduleFrequency(String frequency) {
        try {
            JobSequenceSchedulerController.scheduleRun(frequency);
        } catch (AuraHandledException e) {
            System.debug(LoggingLevel.INFO, 'JobSequenceUtilities()::scheduleFrequency:  e: ' + e.getMessage());
        }
    }

    /**
     * @description Sends an email notification
     *
     * @param toAddresses Optional      A list of email addresses or object IDs of the contacts, leads, and users you’re sending the email to. The maximum number of email addresses allowed is 100.
     * @param ccAddresses Optional      A list of carbon copy (CC) addresses or object IDs of the contacts, leads, and users you’re sending the email to. The maximum allowed is 25.
     * @param whatId Optional           If you specify a contact for the targetObjectId field, you can specify an optional whatId as well. This helps to further ensure that merge fields in the template contain the correct data.
     * @param whoId Required            If using a template, optional otherwise. The ID of the contact, lead, or user to which the email will be sent. The ID you specify sets the context and ensures that merge fields in the template contain the correct data.
     * @param subject Optional          The email subject line. If you are using an email template, the subject line of the template overrides this value.
     * @param body Optional             The text version of the email, specified by the sender. You must specify a value for setTemplateId, setHtmlBody, or setPlainTextBody. Or, you can define both setHtmlBody and setPlainTextBody.
     * @param senderDisplayNm Optional  The name that appears on the From line of the email. This cannot be set if the object associated with a setOrgWideEmailAddressId for a SingleEmailMessage has defined its DisplayName field.
     * @param priority Optional         The priority of the email
     *
     * @return                          The list of resulting emails after sending
     */
    global static List<Messaging.SendEmailResult> sendEmailNotification(
            List<String> toAddresses,
            List<String> ccAddresses,
            String whatId,
            String whoId,
            String subject,
            String body,
            String senderDisplayNm,
            String priority
    ) {
        Messaging.SingleEmailMessage mail = setupSingleEmail(toAddresses, ccAddresses, whatId, whoId, subject, body, senderDisplayNm, priority);

        return Messaging.sendEmail(new List<Messaging.Email>{
                mail
        });
    }


    /**
     * @description This function will setup a scheduled run based on the class name passed and the schedule base don the cron string passed
     * The run is skipped when a scheduled job with the class name already exists.
     *
     * @param className     The name of the scheduled class to run
     * @param cronString    The cron schedule as a string
     */
    global static void setupScheduledRun(String className, String cronString) {
        //Scheduled jobs are tracked in CronTrigger (named after the class), not AsyncApexJob
        List<CronTrigger> existing = [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :className WITH SYSTEM_MODE];
        try {if (existing.isEmpty()) System.schedule(className, cronString, (Schedulable) Type.forName(className).newInstance());} catch (Exception e) {System.debug(LoggingLevel.ERROR, 'JobSequenceUtilities()::setupScheduledRun:  e: ' + e);}

    }

    /**
     * @description Creates an email notification
     *
     * @param toAddresses Optional      A list of email addresses or object IDs of the contacts, leads, and users you’re sending the email to. The maximum number of email addresses allowed is 100.
     * @param ccAddresses Optional      A list of carbon copy (CC) addresses or object IDs of the contacts, leads, and users you’re sending the email to. The maximum allowed is 25.
     * @param whatId Optional           If you specify a contact for the targetObjectId field, you can specify an optional whatId as well. This helps to further ensure that merge fields in the template contain the correct data.
     * @param whoId Required            If using a template, optional otherwise. The ID of the contact, lead, or user to which the email will be sent. The ID you specify sets the context and ensures that merge fields in the template contain the correct data.
     * @param subject Optional          The email subject line. If you are using an email template, the subject line of the template overrides this value.
     * @param body Optional             The text version of the email, specified by the sender. You must specify a value for setTemplateId, setHtmlBody, or setPlainTextBody. Or, you can define both setHtmlBody and setPlainTextBody.
     * @param senderDisplayNm Optional  The name that appears on the From line of the email. This cannot be set if the object associated with a setOrgWideEmailAddressId for a SingleEmailMessage has defined its DisplayName field.
     * @param priority Optional         The priority of the email
     *
     * @return                          The constructed email notification
     */
    global static Messaging.SingleEmailMessage setupSingleEmail(
            List<String> toAddresses,
            List<String> ccAddresses,
            String whatId,
            String whoId,
            String subject,
            String body,
            String senderDisplayNm,
            String priority
    ) {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();

        mail.setToAddresses(toAddresses);
        mail.setCcAddresses(ccAddresses);
        mail.setSenderDisplayName(senderDisplayNm);
        mail.setSubject(subject);
        mail.setUseSignature(false);
        mail.setPlainTextBody(body);
        mail.setSaveAsActivity (false);
        mail.setEmailPriority(priority);
        mail.whatId = whatId;
        mail.targetObjectId = whoId;

        return mail;
    }

    /**
     * @description This function will trim the character from the beginning and end of the string
     *
     * @param value             The value to trim
     * @param character2Trim    The character to trim out of the beginning and end
     *
     * @return                  The string with the character trimmed out.
     */
    /**
     * @description Adds the failed rows of a partial-success insert or update to the DML failure count
     *
     * @param results   The DML results
     */
    private static void countFailures(List<Database.SaveResult> results) {
        for (Database.SaveResult result : results) if (!result.isSuccess()) dmlFailureCount++;
    }

    /**
     * @description Adds the failed rows of a partial-success delete to the DML failure count
     *
     * @param results   The DML results
     */
    private static void countFailures(List<Database.DeleteResult> results) {
        for (Database.DeleteResult result : results) if (!result.isSuccess()) dmlFailureCount++;
    }

    /**
     * @description Adds the failed rows of an upsert to the DML failure count
     *
     * @param results   The DML results
     */
    private static void countFailures(List<Database.UpsertResult> results) {
        if (results == null) return;
        for (Database.UpsertResult result : results) if (!result.isSuccess()) dmlFailureCount++;
    }

    global static String trimCharacters(String value, String character2Trim) {
        value = value.startsWith(character2Trim) ? value.substringAfter(character2Trim) : value;
        value = value.endsWith(character2Trim) ? value.substringBeforeLast(character2Trim) : value;
        return value;
    }
}