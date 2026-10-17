/**
 * @description: **JobSequencerHomeController** -- Apex controller for the jobSequencerHome LWC. Gathers the home page
 * metrics: sequencer status, schedules, active jobs, error trends, recent Job Sequence Runs and recent errors.
 * @author: Gary Butler
 * @date: 10/16/2026
 *
 * Modification Log:
 *   | Date:       | By:               | Change Description                                      |
 *   | ----------- | ----------------- | ------------------------------------------------------- |
 *   |  10/16/2026 |  Gary Butler      | Initial Creation                                        |
 *   |  10/16/2026 |  Gary Butler      | Run metrics, slowest jobs and cleanup warning           |
 *
 */
public with sharing class JobSequencerHomeController {
    @TestVisible private static final Integer CHART_DAYS = 14;
    @TestVisible private static final Integer TREND_DAYS = 7;
    @TestVisible private static final Integer TOP_JOBS_DAYS = 30;
    @TestVisible private static final Integer LIST_SIZE = 5;
    @TestVisible private static final Integer RECENT_RUNS_SIZE = 10;
    //The packaged cleanup sequence jobs, which only run when the Daily frequency is scheduled
    @TestVisible private static final Set<String> CLEANUP_JOBS = new Set<String>{'JOBSEQ_PURGE_RUNS', 'JOBSEQ_PURGE_ERRORS'};
    private static final Integer EXCEPTION_PREVIEW_LENGTH = 160;

    /**
     * @description Everything the home page shows.
     */
    public class HomeData {
        @AuraEnabled public Boolean sequencerEnabled;
        @AuraEnabled public Integer scheduledCount;
        @AuraEnabled public Integer frequencyCount;
        @AuraEnabled public Datetime nextRunTime;
        @AuraEnabled public String nextRunFrequency;
        @AuraEnabled public Integer activeJobCount;
        @AuraEnabled public Integer errorsLast7Days;
        @AuraEnabled public Integer errorsPrior7Days;
        @AuraEnabled public List<DayCount> errorsByDay;
        @AuraEnabled public List<DayCount> recordsByDay;
        @AuraEnabled public List<FrequencyStats> frequencyStats;
        @AuraEnabled public List<JobStats> slowestJobs;
        @AuraEnabled public Boolean cleanupNotScheduled;
        @AuraEnabled public List<JobCount> topFailingJobs;
        @AuraEnabled public List<RecentError> recentErrors;
        @AuraEnabled public List<RecentRun> recentRuns;
    }

    /**
     * @description A count for one day (errors logged, or records processed).
     */
    public class DayCount {
        @AuraEnabled public Date day;
        @AuraEnabled public Integer value;
    }

    /**
     * @description How one frequency's runs performed over the last 7 days.
     */
    public class FrequencyStats {
        @AuraEnabled public String frequency;
        @AuraEnabled public Integer runs;
        @AuraEnabled public Decimal averageSeconds;
        @AuraEnabled public Decimal maxSeconds;
        @AuraEnabled public Integer recordsProcessed;
        @AuraEnabled public Integer recordsFailed;
        @AuraEnabled public Integer timesSkipped;
    }

    /**
     * @description How one sequence job's steps performed over the last 30 days.
     */
    public class JobStats {
        @AuraEnabled public String jobName;
        @AuraEnabled public Integer runs;
        @AuraEnabled public Decimal averageSeconds;
        @AuraEnabled public Integer recordsProcessed;
    }

    /**
     * @description The number of errors logged for one sequence job.
     */
    public class JobCount {
        @AuraEnabled public String jobName;
        @AuraEnabled public Integer errorCount;
    }

    /**
     * @description A recent Job Sequence Error with a short preview of its exception text.
     */
    public class RecentError {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String jobName;
        @AuraEnabled public String frequency;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String exceptionPreview;
    }

    /**
     * @description A recent Job Sequence Run: one run of a frequency's job sequence.
     */
    public class RecentRun {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String name;
        @AuraEnabled public String frequency;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime startedAt;
        @AuraEnabled public Datetime finishedAt;
        @AuraEnabled public String detail;
        @AuraEnabled public Integer jobsRun;
        @AuraEnabled public Integer recordsProcessed;
        @AuraEnabled public Integer recordsFailed;
        @AuraEnabled public Integer timesSkipped;
        @AuraEnabled public Decimal durationSeconds;
    }

    /**
     * @description Builds the home page metrics. Not cacheable, because runs and errors change constantly.
     *
     * @return The home page data
     */
    @AuraEnabled
    public static HomeData getHomeData() {
        HomeData data = new HomeData();
        data.sequencerEnabled = JobSequenceSettingsController.getSettings().Enabled__c == true;
        applyScheduleMetrics(data);
        data.activeJobCount = countActiveJobs();
        Datetime trendStart = Datetime.now().addDays(-TREND_DAYS);
        data.errorsLast7Days = countErrorsBetween(trendStart, null);
        data.errorsPrior7Days = countErrorsBetween(trendStart.addDays(-TREND_DAYS), trendStart);
        data.errorsByDay = getErrorsByDay();
        data.recordsByDay = getRecordsByDay();
        data.frequencyStats = getFrequencyStats();
        data.slowestJobs = getSlowestJobs();
        data.topFailingJobs = getTopFailingJobs();
        data.recentErrors = getRecentErrors();
        data.recentRuns = getRecentRuns();
        System.debug('JobSequencerHomeController()::getHomeData:  data: ' + data);
        return data;
    }

    /**
     * @description Counts the scheduled frequencies and finds the soonest upcoming run.
     *
     * @param data The home data to fill in
     */
    private static void applyScheduleMetrics(HomeData data) {
        JobSequenceSchedulerController.DashboardData schedules = JobSequenceSchedulerController.getDashboardData();
        data.frequencyCount = schedules.frequencies.size();
        data.scheduledCount = 0;
        Boolean dailyScheduled = false;
        for (JobSequenceSchedulerController.FrequencyStatus status : schedules.frequencies) {
            if (status.frequency == 'Daily' && status.isScheduled) dailyScheduled = true;
            if (!status.isScheduled) continue;
            data.scheduledCount++;
            if (status.nextFireTime != null && (data.nextRunTime == null || status.nextFireTime < data.nextRunTime)) {
                data.nextRunTime = status.nextFireTime;
                data.nextRunFrequency = status.frequency;
            }
        }
        data.cleanupNotScheduled = !dailyScheduled && hasActiveCleanupJob();
    }

    /**
     * @description Checks whether a packaged cleanup sequence job is active.
     *
     * @return True when at least one cleanup job is active
     */
    private static Boolean hasActiveCleanupJob() {
        for (String name : CLEANUP_JOBS) {
            Sequence_Job__mdt sj = Sequence_Job__mdt.getInstance(name);
            if (sj != null && sj.Active__c) return true;
        }
        return false;
    }

    /**
     * @description Counts every active Sequence Job record, across all frequencies.
     *
     * @return The number of active sequence jobs
     */
    private static Integer countActiveJobs() {
        Integer count = 0;
        for (Sequence_Job__mdt sj : Sequence_Job__mdt.getAll().values()) {
            if (sj.Active__c) count++;
        }
        return count;
    }

    /**
     * @description Counts the Job Sequence Errors created in a time window.
     *
     * @param since   The start of the window (inclusive)
     * @param untilDt The end of the window (exclusive), or null for no end
     *
     * @return The number of errors in the window
     */
    private static Integer countErrorsBetween(Datetime since, Datetime untilDt) {
        if (untilDt == null) {
            return [SELECT COUNT() FROM Job_Sequence_Error__c WHERE CreatedDate >= :since WITH SYSTEM_MODE];
        }
        return [
                SELECT COUNT() FROM Job_Sequence_Error__c
                WHERE CreatedDate >= :since AND CreatedDate < :untilDt
                WITH SYSTEM_MODE
        ];
    }

    /**
     * @description Counts errors per day for the chart, in the running user's time zone, including days with none.
     *
     * @return One entry per day, oldest first
     */
    private static List<DayCount> getErrorsByDay() {
        Date firstDay = Date.today().addDays(-(CHART_DAYS - 1));
        Map<Date, Integer> countsByDay = new Map<Date, Integer>();
        for (AggregateResult ar : [
                SELECT DAY_ONLY(convertTimezone(CreatedDate)) errorDay, COUNT(Id) errorCount
                FROM Job_Sequence_Error__c
                WHERE CreatedDate = LAST_N_DAYS:13
                WITH SYSTEM_MODE
                GROUP BY DAY_ONLY(convertTimezone(CreatedDate))
        ]) {
            countsByDay.put((Date) ar.get('errorDay'), (Integer) ar.get('errorCount'));
        }
        return toDays(firstDay, countsByDay);
    }

    /**
     * @description Sums the records processed by runs started each day, in the running user's time zone.
     *
     * @return One entry per day, oldest first
     */
    private static List<DayCount> getRecordsByDay() {
        Date firstDay = Date.today().addDays(-(CHART_DAYS - 1));
        Map<Date, Integer> recordsByDay = new Map<Date, Integer>();
        for (AggregateResult ar : [
                SELECT DAY_ONLY(convertTimezone(StartedAt__c)) runDay, SUM(RecordsProcessed__c) records
                FROM Job_Sequence_Run__c
                WHERE StartedAt__c = LAST_N_DAYS:13
                WITH SYSTEM_MODE
                GROUP BY DAY_ONLY(convertTimezone(StartedAt__c))
        ]) {
            Decimal records = (Decimal) ar.get('records');
            recordsByDay.put((Date) ar.get('runDay'), records == null ? 0 : records.intValue());
        }
        return toDays(firstDay, recordsByDay);
    }

    /**
     * @description Turns per-day values into one entry per chart day, filling in days with none.
     *
     * @param firstDay    The first day of the chart
     * @param valuesByDay The values that exist
     *
     * @return One entry per day, oldest first
     */
    private static List<DayCount> toDays(Date firstDay, Map<Date, Integer> valuesByDay) {
        List<DayCount> days = new List<DayCount>();
        for (Integer i = 0; i < CHART_DAYS; i++) {
            DayCount dc = new DayCount();
            dc.day = firstDay.addDays(i);
            dc.value = valuesByDay.containsKey(dc.day) ? valuesByDay.get(dc.day) : 0;
            days.add(dc);
        }
        return days;
    }

    /**
     * @description Summarizes each frequency's runs over the last 7 days.
     *
     * @return One entry per frequency that ran, by frequency name
     */
    private static List<FrequencyStats> getFrequencyStats() {
        List<FrequencyStats> stats = new List<FrequencyStats>();
        for (AggregateResult ar : [
                SELECT Frequency__c frequency, COUNT(Id) runs, AVG(DurationSeconds__c) averageSeconds, MAX(DurationSeconds__c) maxSeconds,
                        SUM(RecordsProcessed__c) recordsProcessed, SUM(RecordsFailed__c) recordsFailed, SUM(TimesSkipped__c) timesSkipped
                FROM Job_Sequence_Run__c
                WHERE StartedAt__c = LAST_N_DAYS:6
                WITH SYSTEM_MODE
                GROUP BY Frequency__c
                ORDER BY Frequency__c
        ]) {
            FrequencyStats fs = new FrequencyStats();
            fs.frequency = (String) ar.get('frequency');
            fs.runs = (Integer) ar.get('runs');
            fs.averageSeconds = roundOrNull((Decimal) ar.get('averageSeconds'));
            fs.maxSeconds = roundOrNull((Decimal) ar.get('maxSeconds'));
            fs.recordsProcessed = intOrZero((Decimal) ar.get('recordsProcessed'));
            fs.recordsFailed = intOrZero((Decimal) ar.get('recordsFailed'));
            fs.timesSkipped = intOrZero((Decimal) ar.get('timesSkipped'));
            stats.add(fs);
        }
        return stats;
    }

    /**
     * @description Finds the sequence jobs with the longest average step duration over the last 30 days.
     *
     * @return Up to five jobs, slowest first
     */
    private static List<JobStats> getSlowestJobs() {
        List<JobStats> jobs = new List<JobStats>();
        for (AggregateResult ar : [
                SELECT SequenceJob__c jobName, COUNT(Id) runs, AVG(DurationSeconds__c) averageSeconds, SUM(RecordsProcessed__c) recordsProcessed
                FROM Job_Sequence_Run_Step__c
                WHERE StartedAt__c = LAST_N_DAYS:29
                WITH SYSTEM_MODE
                GROUP BY SequenceJob__c
                ORDER BY AVG(DurationSeconds__c) DESC NULLS LAST
                LIMIT :LIST_SIZE
        ]) {
            JobStats js = new JobStats();
            js.jobName = String.isBlank((String) ar.get('jobName')) ? 'Unknown' : (String) ar.get('jobName');
            js.runs = (Integer) ar.get('runs');
            js.averageSeconds = roundOrNull((Decimal) ar.get('averageSeconds'));
            js.recordsProcessed = intOrZero((Decimal) ar.get('recordsProcessed'));
            jobs.add(js);
        }
        return jobs;
    }

    /**
     * @description Rounds a number of seconds to one decimal place.
     *
     * @param value The value, or null
     *
     * @return The rounded value, or null
     */
    private static Decimal roundOrNull(Decimal value) {
        return value == null ? null : value.setScale(1);
    }

    /**
     * @description Converts an aggregate sum to a whole number.
     *
     * @param value The value, or null
     *
     * @return The value, or 0
     */
    private static Integer intOrZero(Decimal value) {
        return value == null ? 0 : value.intValue();
    }

    /**
     * @description Finds the sequence jobs with the most errors over the last 30 days.
     *
     * @return Up to five jobs, most errors first
     */
    private static List<JobCount> getTopFailingJobs() {
        List<JobCount> jobs = new List<JobCount>();
        for (AggregateResult ar : [
                SELECT JobName__c jobName, COUNT(Id) errorCount
                FROM Job_Sequence_Error__c
                WHERE CreatedDate = LAST_N_DAYS:29
                WITH SYSTEM_MODE
                GROUP BY JobName__c
                ORDER BY COUNT(Id) DESC
                LIMIT :LIST_SIZE
        ]) {
            JobCount jc = new JobCount();
            jc.jobName = String.isBlank((String) ar.get('jobName')) ? 'Unknown' : (String) ar.get('jobName');
            jc.errorCount = (Integer) ar.get('errorCount');
            jobs.add(jc);
        }
        return jobs;
    }

    /**
     * @description Returns the newest Job Sequence Errors.
     *
     * @return Up to five errors, newest first
     */
    private static List<RecentError> getRecentErrors() {
        List<RecentError> errors = new List<RecentError>();
        for (Job_Sequence_Error__c jse : [
                SELECT Id, Name, JobName__c, JobFrequency__c, CreatedDate, Exception__c
                FROM Job_Sequence_Error__c
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT :LIST_SIZE
        ]) {
            RecentError re = new RecentError();
            re.recordId = jse.Id;
            re.name = jse.Name;
            re.jobName = jse.JobName__c;
            re.frequency = jse.JobFrequency__c;
            re.createdDate = jse.CreatedDate;
            re.exceptionPreview = String.isBlank(jse.Exception__c) ? '' : jse.Exception__c.abbreviate(EXCEPTION_PREVIEW_LENGTH);
            errors.add(re);
        }
        return errors;
    }

    /**
     * @description Returns the newest Job Sequence Runs, including skipped ones.
     *
     * @return Up to ten runs, newest first
     */
    private static List<RecentRun> getRecentRuns() {
        List<RecentRun> runs = new List<RecentRun>();
        for (Job_Sequence_Run__c record : [
                SELECT Id, Name, Frequency__c, Status__c, StartedAt__c, FinishedAt__c, Detail__c, JobsRun__c,
                        RecordsProcessed__c, RecordsFailed__c, TimesSkipped__c, DurationSeconds__c
                FROM Job_Sequence_Run__c
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC, Name DESC
                LIMIT :RECENT_RUNS_SIZE
        ]) {
            RecentRun run = new RecentRun();
            run.recordId = record.Id;
            run.name = record.Name;
            run.frequency = record.Frequency__c;
            run.status = record.Status__c;
            run.startedAt = record.StartedAt__c;
            run.finishedAt = record.FinishedAt__c;
            run.detail = record.Detail__c;
            run.jobsRun = intOrZero(record.JobsRun__c);
            run.recordsProcessed = intOrZero(record.RecordsProcessed__c);
            run.recordsFailed = intOrZero(record.RecordsFailed__c);
            run.timesSkipped = intOrZero(record.TimesSkipped__c);
            run.durationSeconds = record.DurationSeconds__c;
            runs.add(run);
        }
        return runs;
    }
}
