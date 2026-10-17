/**
 * @description jobSequenceSearchSelect -- A searchable dropdown (combobox with type-ahead) for long option lists such as
 * every object or field in the org. Options can be grouped (e.g. Fields, Related lists); each shows its label with its
 * detail (API name, type) on the line below. Fires a "select" event with the chosen value.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement, api } from 'lwc';

const MAX_RESULTS = 60;

export default class JobSequenceSearchSelect extends LightningElement {
    @api label;
    @api placeholder = 'Search';
    @api fieldLevelHelp;
    @api disabled = false;
    // Values to leave out of the list, e.g. fields already selected
    @api excludeValues = [];
    // Shown in the box when nothing is being typed (single-value pickers)
    @api selectedLabel;

    _options = [];
    searchTerm = '';
    isOpen = false;
    activeIndex = 0;
    listboxId = `listbox-${Math.random().toString(36).slice(2)}`;

    /**
     * @description The options: [{ label, value, detail?, group? }]. Options with a group are shown under its header,
     * in the order given.
     */
    @api
    get options() {
        return this._options;
    }
    set options(value) {
        this._options = value || [];
    }

    get inputValue() {
        return this.isOpen || this.searchTerm ? this.searchTerm : this.selectedLabel || '';
    }

    /**
     * @description The options matching the search term (label, value or detail), capped for performance.
     * @returns {Object[]} The matching options
     */
    get matches() {
        const term = this.searchTerm.trim().toLowerCase();
        const excluded = new Set((this.excludeValues || []).map((v) => String(v).toLowerCase()));
        return this._options
            .filter((o) => !excluded.has(String(o.value).toLowerCase()))
            .filter(
                (o) =>
                    !term ||
                    o.label.toLowerCase().includes(term) ||
                    String(o.value).toLowerCase().includes(term) ||
                    (o.detail || '').toLowerCase().includes(term)
            )
            .slice(0, MAX_RESULTS);
    }

    /**
     * @description The rows to render: group headers followed by their options, with display state.
     * @returns {Object[]} The list rows
     */
    get rows() {
        const rows = [];
        let lastGroup;
        this.matches.forEach((o, index) => {
            if (o.group && o.group !== lastGroup) {
                rows.push({ key: `header-${o.group}`, isHeader: true, label: o.group });
                lastGroup = o.group;
            }
            const isActive = index === this.activeIndex;
            rows.push({
                ...o,
                key: `${o.group || ''}-${o.value}`,
                isHeader: false,
                index,
                optionId: `${this.listboxId}-${index}`,
                ariaSelected: isActive ? 'true' : 'false',
                className: `slds-media slds-listbox__option slds-listbox__option_entity option${isActive ? ' slds-has-focus' : ''}`,
                detail: o.detail || o.value
            });
        });
        return rows;
    }

    get hasResults() {
        return this.matches.length > 0;
    }

    get comboboxClass() {
        return `slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click${this.isOpen ? ' slds-is-open' : ''}`;
    }

    get activeDescendant() {
        return this.matches[this.activeIndex] ? `${this.listboxId}-${this.activeIndex}` : undefined;
    }

    get ariaExpanded() {
        return this.isOpen ? 'true' : 'false';
    }

    handleFocus() {
        this.isOpen = true;
        this.activeIndex = 0;
    }

    handleBlur() {
        // Let a click on an option register before the list closes
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.isOpen = false;
            this.searchTerm = '';
        }, 200);
    }

    handleInput(event) {
        this.searchTerm = event.target.value;
        this.isOpen = true;
        this.activeIndex = 0;
    }

    handleKeyDown(event) {
        const count = this.matches.length;
        if (event.key === 'ArrowDown') {
            event.preventDefault();
            this.isOpen = true;
            this.activeIndex = count ? (this.activeIndex + 1) % count : 0;
        } else if (event.key === 'ArrowUp') {
            event.preventDefault();
            this.activeIndex = count ? (this.activeIndex - 1 + count) % count : 0;
        } else if (event.key === 'Enter') {
            event.preventDefault();
            const active = this.matches[this.activeIndex];
            if (this.isOpen && active) this.choose(active.value);
        } else if (event.key === 'Escape') {
            this.isOpen = false;
            this.searchTerm = '';
        }
    }

    handleOptionMouseDown(event) {
        // mousedown fires before the input's blur, so the choice is not lost
        event.preventDefault();
        this.choose(event.currentTarget.dataset.value);
    }

    /**
     * @description Reports the chosen value and resets the search.
     * @param {String} value The chosen option value
     */
    choose(value) {
        this.dispatchEvent(new CustomEvent('select', { detail: { value } }));
        this.searchTerm = '';
        this.activeIndex = 0;
    }
}
