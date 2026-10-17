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
 * @description: **JobSequenceVisualforceCont** -- This controller handles functions for Job Sequencer visualforce pages
 * @author: Jason Hardy
 * @date: 10/26/2019
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/26/2019 |  Jason Hardy      | Initial Creation (original author)                      |
 *   |  10/16/2026 |  Gary Butler      | Fork: Select/Where/Params LongTextArea for complex SOQL |
 *   |  10/16/2026 |  Gary Butler      | Added ApexDoc comments                                  |
 *   |  10/16/2026 |  Gary Butler      | API version 45.0 -> 68.0                                |
 *   |  10/17/2026 |  Gary Butler      | Remove page redirects for the deleted Visualforce pages |
 *
 */
public with sharing class JobSequenceVisualforceCont {
    /**
     * @description Default constructor for the Job Sequencer Visualforce pages.
     */
    public JobSequenceVisualforceCont() {}

    /**
     * @description Schedules all of the out of the box job sequence runs
     */
    public void scheduleAllRuns() {
        JobSequenceUtilities.scheduleAllRuns();
    }

    /**
     * @description This function will schedule the hourly class
     */
    public void scheduleHourlyRun() {
        JobSequenceUtilities.scheduleHourlyRun();
    }

    /**
     * @description This function will schedule the daily class
     */
    public void scheduleDailyRun() {
        JobSequenceUtilities.scheduleDailyRun();
    }

    /**
     * @description This function will schedule the weekly class
     */
    public void scheduleWeeklyRun() {
        JobSequenceUtilities.scheduleWeeklyRun();
    }

    /**
     * @description This function will schedule the monthly class
     */
    public void scheduleMonthlyRun() {
        JobSequenceUtilities.scheduleMonthlyRun();
    }

    /**
     * @description This function will schedule the quarterly class
     */
    public void scheduleQuarterlyRun() {
        JobSequenceUtilities.scheduleQuarterlyRun();
    }

    /**
     * @description This function will schedule the yearly class
     */
    public void scheduleYearlyRun() {
        JobSequenceUtilities.scheduleYearlyRun();
    }
}