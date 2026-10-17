/**
 * @description: **JobSequenceScheduledRun** -- The single schedulable class for every frequency (every 5 minutes
 * through yearly). Kept deliberately minimal: scheduled jobs block deployments of the class they run, so all logic
 * lives in JobSequenceRunService and this class should not need to change.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *
 */
public with sharing class JobSequenceScheduledRun implements Schedulable {
    @TestVisible private final String frequency;

    /**
     * @description Creates the schedulable for one frequency.
     *
     * @param frequency The frequency whose job sequence this schedule runs
     */
    public JobSequenceScheduledRun(String frequency) {
        this.frequency = frequency;
    }

    /**
     * @description Starts a run of the frequency's job sequence (or records it as skipped).
     *
     * @param sc The schedulable context supplied by the platform
     */
    public void execute(SchedulableContext sc) {
        JobSequenceRunService.startRun(this.frequency);
    }
}
