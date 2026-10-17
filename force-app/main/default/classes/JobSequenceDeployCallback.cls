/**
 * @description: **JobSequenceDeployCallback** -- Receives the result of a Sequence Job save (an Apex metadata
 * deployment) and publishes it as a Job Sequencer Deploy Result platform event for the Sequence Jobs tab.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
public with sharing class JobSequenceDeployCallback implements Metadata.DeployCallback {
    private static final Integer MESSAGE_LIMIT = 32000;

    /**
     * @description Publishes the deployment outcome, with every component failure, as a platform event.
     *
     * @param result  The deployment result
     * @param context The callback context supplied by the platform
     */
    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        Job_Sequencer_Deploy_Result__e event = buildEvent(result);
        Database.SaveResult saveResult = EventBus.publish(event);
        System.debug('JobSequenceDeployCallback()::handleResult:  event: ' + event);
        System.debug('JobSequenceDeployCallback()::handleResult:  published: ' + saveResult.isSuccess());
    }

    /**
     * @description Turns a deployment result into the platform event published to the Sequence Jobs tab.
     *
     * @param result The deployment result
     *
     * @return The event to publish
     */
    @TestVisible
    private static Job_Sequencer_Deploy_Result__e buildEvent(Metadata.DeployResult result) {
        List<String> problems = new List<String>();
        if (result.details != null && result.details.componentFailures != null) {
            for (Metadata.DeployMessage failure : result.details.componentFailures) {
                problems.add(failure.fullName + ': ' + failure.problem);
            }
        }
        if (String.isNotBlank(result.errorMessage)) {
            problems.add(result.errorMessage);
        }
        return new Job_Sequencer_Deploy_Result__e(
                DeploymentId__c = result.id,
                Status__c = String.valueOf(result.status),
                Message__c = String.join(problems, '\n').left(MESSAGE_LIMIT)
        );
    }
}
