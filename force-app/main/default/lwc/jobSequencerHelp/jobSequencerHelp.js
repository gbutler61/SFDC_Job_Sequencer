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
 * @description jobSequencerHelp -- The Job Sequencer guide with a section menu. Replaces the JobSequenceHelp
 * Visualforce page; much of the guide text is Jason Hardy's (Copyright 2019, BSD 3-Clause), with sections added and
 * updated for this fork.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// Sections in page order; names match the data-id of each section in the template
const SECTIONS = [
    { name: 'about', label: 'About This Guide' },
    { name: 'manage_job_sequencer_settings', label: 'Managing Job Sequencer Settings' },
    { name: 'new_sequence_job', label: 'Creating a New Sequence Job' },
    { name: 'modify_js', label: "Modifying existing Sequence Job's" },
    { name: 'sequence_job_fields', label: 'Sequence Job Fields' },
    { name: 'reviewing_errors', label: 'Reviewing Errors' },
    { name: 'job_parameters', label: 'Job Parameters and Variables' },
    { name: 'common_functions', label: 'Common Functions in the Default Handler' },
    { name: 'using_custom_handler', label: 'Using a Custom Handler' },
    { name: 'scheduling_jobs', label: 'Scheduling Jobs' },
    { name: 'running_on_demand', label: 'Running Jobs on Demand' },
    { name: 'run_history', label: 'Run History and Cleanup' },
    { name: 'security_model', label: 'Security Model' },
    { name: 'pro_tips', label: 'Pro Tips' },
    { name: 'legal', label: 'Legal Disclosure' }
];

export default class JobSequencerHelp extends NavigationMixin(LightningElement) {
    sections = SECTIONS;
    selectedSection = SECTIONS[0].name;

    // Text containing braces can't be written literally in an LWC template, so it is bound from here
    settingsTokenExample = '{!Settings.FieldName__c}';
    tokens = {
        variable: '{!Var.name}',
        cutoff: '{!Var.cutoff}',
        settings: '{!Settings.Field__c}',
        label: '{!Label.Name}',
        mdt: '{!Mdt.Type__mdt.Record.Field__c}',
        now: '{!Now}',
        today: '{!Today}',
        userId: '{!UserId}'
    };
    parametersExample = "{\n  \"version\": 1,\n  \"variables\": [\n    {\n      \"name\": \"openStages\",\n      \"type\": \"TextList\",\n      \"value\": \"Prospecting, Qualification\"\n    },\n    {\n      \"name\": \"cutoff\",\n      \"type\": \"RelativeDate\",\n      \"value\": \"-90 days\",\n      \"testValue\": \"+1 days\"\n    },\n    {\n      \"name\": \"testOnlyFilter\",\n      \"type\": \"SoqlFragment\",\n      \"testValue\": \"AND Name LIKE 'Test%'\"\n    }\n  ]\n}";
    whereExample = "StageName IN {!Var.openStages} AND CloseDate < {!Var.cutoff} {!Var.testOnlyFilter}";
    resolvedExample = "StageName IN ('Prospecting','Qualification') AND CloseDate < 2026-07-19";
    resolvedTestExample = "StageName IN ('Prospecting','Qualification') AND CloseDate < 2026-10-18 AND Name LIKE 'Test%'";
    fieldShiftExample = "{\n  \"version\": 1,\n  \"fieldValues\": [\n    {\n      \"field\": \"StageName\",\n      \"value\": \"Closed Lost\"\n    },\n    {\n      \"field\": \"Description\",\n      \"blank\": true\n    },\n    {\n      \"field\": \"Closed_On__c\",\n      \"value\": \"{!Today}\"\n    }\n  ]\n}";
    handlerExample = "{\n  \"version\": 1,\n  \"handlerParameters\": {\n    \"MyCustom\": \"42\",\n    \"Since\": \"{!Var.cutoff}\"\n  }\n}";

    handleNavigate(event) {
        this.selectedSection = event.detail.name;
        this.scrollToSection(event.detail.name);
    }

    /**
     * @description Follows an in-page link to another section or field description.
     * @param {Event} event The click event from a link with a data-target attribute
     */
    handleJump(event) {
        event.preventDefault();
        const target = event.currentTarget.dataset.target;
        if (SECTIONS.some((section) => section.name === target)) {
            this.selectedSection = target;
        }
        this.scrollToSection(target);
    }

    /**
     * @description Opens another Job Sequencer tab.
     * @param {Event} event The click event from a button with a data-tab attribute holding the tab API name
     */
    handleOpenTab(event) {
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: event.currentTarget.dataset.tab }
        });
    }

    /**
     * @description Scrolls the section or field description with the given data-id into view.
     * @param {String} id The data-id to scroll to
     */
    scrollToSection(id) {
        const element = this.template.querySelector(`[data-id="${id}"]`);
        if (element) {
            element.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }
}
