/**
 * @description jobSequencerHelp -- The Job Sequencer guide with a section menu. Replaces the JobSequenceHelp
 * Visualforce page; the guide text is Jason Hardy's (Copyright 2019, BSD 3-Clause), updated for this fork.
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
    { name: 'handling_test_classes', label: 'Handling Test Classes' },
    { name: 'common_functions', label: 'Common Functions in the Default Handler' },
    { name: 'using_custom_handler', label: 'Using a Custom Handler' },
    { name: 'scheduling_jobs', label: 'Scheduling Jobs' },
    { name: 'run_history', label: 'Run History and Cleanup' },
    { name: 'security_model', label: 'Security Model' },
    { name: 'pro_tips', label: 'Pro Tips' },
    { name: 'legal', label: 'Legal Disclosure' }
];

export default class JobSequencerHelp extends NavigationMixin(LightningElement) {
    sections = SECTIONS;
    selectedSection = SECTIONS[0].name;

    // Text containing braces can't be written literally in an LWC template, so it is bound from here
    placeholderToken = '{0}';
    placeholderWhereExample = "StatusField = 'xyz' {0}";
    settingsTokenExample = '{!Settings.FieldName__c}';

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
