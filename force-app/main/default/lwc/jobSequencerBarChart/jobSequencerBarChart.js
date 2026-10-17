/**
 * @description jobSequencerBarChart -- A single-series column chart of one value per day (e.g. errors logged or
 * records processed), drawn in SVG with a hover/focus tooltip and a table view for accessibility.
 * @author Gary Butler
 * @date 10/16/2026
 */
import { LightningElement, api } from 'lwc';
import LOCALE from '@salesforce/i18n/locale';

// Geometry in SVG viewBox units; the SVG scales to the container width
const CHART = { width: 640, height: 210, top: 14, right: 8, bottom: 30, left: 40, maxBarWidth: 24, barRadius: 4 };
const TICK_COUNT = 4;

/**
 * @description Picks a clean tick step (1, 2 or 5 times a power of ten) so the y-axis shows whole numbers.
 * @param {Number} maxValue The largest value on the chart
 * @returns {Number} The tick step
 */
function niceStep(maxValue) {
    const raw = Math.max(maxValue, 1) / TICK_COUNT;
    const magnitude = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 5, 10].map((m) => m * magnitude).find((s) => s >= raw);
    return Math.max(1, Math.ceil(step));
}

/**
 * @description Builds an SVG path for a column with rounded top corners and a square base.
 * @returns {String} The path data
 */
function columnPath(x, y, w, h, radius) {
    const r = Math.min(radius, h, w / 2);
    const base = y + h;
    return `M${x},${base} L${x},${y + r} Q${x},${y} ${x + r},${y} L${x + w - r},${y} Q${x + w},${y} ${x + w},${y + r} L${x + w},${base} Z`;
}

/**
 * @description Parses an Apex Date (yyyy-mm-dd) as a local calendar date.
 * @param {String} value The date string
 * @returns {Date} The local date
 */
function parseDay(value) {
    const [year, month, day] = value.split('-').map(Number);
    return new Date(year, month - 1, day);
}

export default class JobSequencerBarChart extends LightningElement {
    @api chartTitle;
    // Unit names for tooltips and the table, e.g. "error" / "errors"
    @api unitSingular = 'item';
    @api unitPlural = 'items';
    @api emptyMessage;

    chart;
    showTable = false;
    activeIndex = -1;

    numberFormatter = new Intl.NumberFormat(LOCALE);
    compactFormatter = new Intl.NumberFormat(LOCALE, { notation: 'compact', maximumFractionDigits: 1 });
    dayFormatter = new Intl.DateTimeFormat(LOCALE, { month: 'short', day: 'numeric' });
    longDayFormatter = new Intl.DateTimeFormat(LOCALE, { weekday: 'short', month: 'short', day: 'numeric' });

    _days = [];

    /**
     * @description The values to chart, one per day: [{ day: 'yyyy-mm-dd', value: Number }].
     */
    @api
    get days() {
        return this._days;
    }
    set days(value) {
        this._days = value || [];
        this.chart = this.buildChart();
        this.activeIndex = -1;
    }

    get toggleLabel() {
        return this.showTable ? 'View as chart' : 'View as table';
    }

    get isEmpty() {
        return !this._days.some((d) => d.value > 0);
    }

    get activeBar() {
        return this.activeIndex >= 0 && this.chart ? this.chart.bars[this.activeIndex] : undefined;
    }

    get tooltipStyle() {
        const bar = this.activeBar;
        if (!bar) return '';
        return `left: ${(bar.centerX / CHART.width) * 100}%; top: ${(bar.topY / CHART.height) * 100}%;`;
    }

    get ariaLabel() {
        return `${this.chartTitle}. Use the table view for exact values.`;
    }

    /**
     * @description Lays out the columns, ticks and labels in SVG viewBox units.
     * @returns {Object} The chart geometry used by the template
     */
    buildChart() {
        const days = this._days;
        const plotWidth = CHART.width - CHART.left - CHART.right;
        const plotHeight = CHART.height - CHART.top - CHART.bottom;
        const step = niceStep(Math.max(0, ...days.map((d) => d.value)));
        const axisMax = step * TICK_COUNT;
        const band = plotWidth / Math.max(days.length, 1);
        const barWidth = Math.min(CHART.maxBarWidth, band * 0.6);
        const yFor = (value) => CHART.top + plotHeight - (value / axisMax) * plotHeight;

        const ticks = [];
        for (let i = 0; i <= TICK_COUNT; i++) {
            const value = step * i;
            ticks.push({ key: `t${i}`, label: this.compactFormatter.format(value), y: yFor(value), labelY: yFor(value) + 4 });
        }

        const bars = days.map((d, index) => {
            const date = parseDay(d.day);
            const centerX = CHART.left + band * index + band / 2;
            const y = yFor(d.value);
            const label = this.longDayFormatter.format(date);
            const valueText = `${this.numberFormatter.format(d.value)} ${d.value === 1 ? this.unitSingular : this.unitPlural}`;
            return {
                key: d.day,
                index,
                valueText,
                hasBar: d.value > 0,
                path: d.value > 0 ? columnPath(centerX - barWidth / 2, y, barWidth, CHART.top + plotHeight - y, CHART.barRadius) : '',
                hitX: CHART.left + band * index,
                hitWidth: band,
                showAxisLabel: index % 2 === (days.length - 1) % 2,
                axisLabel: this.dayFormatter.format(date),
                centerX,
                topY: d.value > 0 ? y : CHART.top + plotHeight,
                label,
                ariaLabel: `${label}: ${valueText}`
            };
        });

        return {
            bars,
            ticks,
            plotTop: CHART.top,
            plotHeight,
            baselineY: CHART.top + plotHeight,
            axisLabelY: CHART.height - 8,
            plotLeft: CHART.left,
            plotRight: CHART.width - CHART.right,
            tickLabelX: CHART.left - 6
        };
    }

    handleToggle() {
        this.showTable = !this.showTable;
        this.activeIndex = -1;
    }

    handleBarEnter(event) {
        this.activeIndex = Number(event.currentTarget.dataset.index);
    }

    handleBarLeave() {
        this.activeIndex = -1;
    }
}
