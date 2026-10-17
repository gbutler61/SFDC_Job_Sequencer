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
 * @description: **JobSequenceDefaultHandler** -- This is the default handler for the job sequencer
 * If you wish to create your own custom version of this class, simply copy the relevant implementation portions and
 * define your own custom logic. Then all you need to do is reference the custom handler in your Sequence Job Custom
 * Meta Data Type record in the "Handler Class" field.
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
 *   |  10/17/2026 |  Gary Butler      | List its functions (JobSequenceFunctionCatalog)         |
 *   |  10/17/2026 |  Gary Butler      | FieldShift reads the field values in Job Parameters     |
 *
 */
global without sharing class JobSequenceDefaultHandler implements JobSequenceInterface, JobSequenceFunctionCatalog {

    /**
     * @description Lists the functions executeFunction handles, for the Sequence Jobs tab's function dropdown. Add new
     * function names here when you add them to executeFunction.
     *
     * @return The function names
     */
    global List<String> getFunctionNames() {
        return new List<String>{'FieldShift'};
    }

    /**
     * @description This method will execute functions based on the function name defined in the "Execution Job" defined on the
     * sequence job custom setting, which is translated into a jobs sequence object wrapper. Each function has to be
     * defined as an option in a case statement (or if statements whichever works best for you), pointing to the
     * appropriate function either in this class or in another.
     *
     * Having the ability to run a function provides you with the ability to scale your job sequences. By providing an
     * interface you may work with, you can either adapt this class or create your own and point the sequence job custom
     * metadata type to the "Handler" of your choice. Thus you can create custom functions that meet the business needs
     * for the jobs you need to have executed in a serial fashion.
     *
     * You are able to scale this further by using parameters which can be defined in a JSON fashion in either a test
     * or production fashion, see the help documentation for further details.
     *
     * @param js    The job sequence wrapped object containing the logic needed to execute the function
     * @param scope The records to be worked with
     *
     * @throws JobSequenceException when the execution job does not match a known function
     */
    global void executeFunction(JobSequence js, List<SObject> scope) {
        if (String.isNotBlank(js.executionJob)) {
            switch on js.executionJob.toUpperCase() {
                when 'FIELDSHIFT' {fieldShift(js, scope);}
                when else {js.noFunctionFoundError();}
            }
        }
    }

    /**
     * @description This method will simply run a DML option based on how you've defined it in the Sequence Job Custom Meta data type
     *
     * @param js    The job sequence wrapped object containing the logic needed to execute the function
     * @param scope The records to be worked with
     */
    global void executeDML(JobSequence js, List<SObject> scope) {
        JobSequenceUtilities.attemptJobSequenceDML(scope, js.executionJob, js.upsertField, js.allOrNone, js.permDelete);
    }

    /**
     * @description If you wish some custom logic to be executed when the job sequence is completed, this is where you can do so.
     * An example would be sending an email to let someone know that the sequence has been completed successfully.
     *
     * @param js    The job sequence wrapped object containing the logic needed to execute the function
     */
    global void finishJobSequence(JobSequence js) {
        //This code will look for any job sequence errors for a queueable job and send an email with the errors found
        if (js != null && !js.isBatchJob) {
            if (js.jobId != null) {
                List<Job_Sequence_Error__c> errors = [SELECT Id FROM Job_Sequence_Error__c WHERE BatchJobId__c = :js.jobId WITH SYSTEM_MODE];
                if (!errors.isEmpty()) js.sendErrorEmail(js.jobId, errors);
            }
        }
    }

    /**
     * @description This method will shift field values to a new value
     * The values come from the field values in the Job Parameters (js.fieldValuesByField)
     *
     * @param js    The job sequence wrapped object containing the logic needed to execute the function
     * @param scope The records to be worked with
     */
    @TestVisible void fieldShift(JobSequence js, List<SObject> scope) {
        if (!scope.isEmpty()) {
            Map<String, String> params = js.fieldValuesByField;
            Map<String, Schema.SObjectField> fldMap = scope[0].getSObjectType().getDescribe().fields.getMap();
            if (params != null && !params.isEmpty()) {
                for (SObject sobj : scope) {
                    JobSequenceUtilities.changeSobjectValueFromParameters(sobj, fldMap, params);
                }
            }
            JobSequenceUtilities.attemptJobSequenceDML(scope, 'UPDATE', js.allOrNone);
        }
    }

}