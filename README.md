> **About this fork:** This is a fork of [coldeagle/SFDC_Job_Sequencer](https://github.com/coldeagle/SFDC_Job_Sequencer), created and copyrighted by Jason Hardy (BSD 3-Clause, see [LICENSE](LICENSE)). It exists solely to change the Sequence Job fields **Job Parameters** (`Parameters__c`), **Query - Select** (`Select__c`) and **Query - Where** (`Where__c`) from Text Area to Long Text Area (20,000 characters), so sequence jobs can hold more complex queries. ApexDoc comments were also added to the classes. Version 1.1.0 added the Job Sequence Scheduler and Job Sequencer Settings tabs (Lightning Web Components), the Job Sequencer Admin permission set, and the move to API 68.0. Version 1.2.0 adds a Lightning app with a metrics home page, the Sequence Jobs tab with a query wizard, sub-hourly frequencies, skipping a run while the previous one is still going, run and per-job metrics, settings tokens, and cleanup jobs that run on the sequencer itself. The sequencing engine and all other functionality are Jason Hardy's original work.

# What is the Job Sequencer
The tool provides it's users with the ability to schedule jobs on a hourly, daily, weekly, monthly, quarterly or yearly basis. Sequence jobs are created with a frequency based on those Schedules.

# Why should I care
This tools ability to create sequence jobs that run on a schedule. This provides a level of flexibility that is difficult to achieve out of the box. 

And you're saying to your self "Ok that sounds great but why is this important." Well think about it this way. You've got 10 things that need to run on x basis. Traditionally, you would need to either create a class that would run a bunch of code synchronously and run the risk of hitting governor limits.  Another approach could be create separate classes and schedule them to run; however, you could run into limits there as there are a finite number of classes that can be scheduled (100 total). Additionally, if you've got two jobs running at the same time, you could run into row locks. If the jobs are batch apex, you have a limit there as well.

Another problem with these approaches is that it's difficult for you to create those jobs without writing code unless you try to use time-based workflow's. There are some limits there too. 

# How does the tool work
So now you know why the tool could be helpful, now let's see how it works. Once installed, this tool has a metadata type "Sequence Job" that can be configured with the frequency that the it should be run at (hourly, daily, etc). Each sequence job is run asynchronously in either a batch or queueable context. 

Once the actual scheduled job is run by Salesforce, queueable apex is used to execute each of the sequence job's serially. Each sequence job is enqueued based on which type of job its defined as being (either batch or queueable). Once the job completes, a queueable job is enqueued that will run the next sequence job. 

Each of the sequence jobs can be setup to either run a function or a DML statement. 

## DML

The DML options that are available to be run are either UPDATE or DELETE. The update portion is helpful if you want to replace a time-based workflow rule. For example, let's say that you want an email alert to be sent when the CloseDate of an opportunity is today. You would setup a sequence job with a query like this:

```SELECT Id FROM Opportunity WHERE CloseDate = TODAY AND IsClosed = FALSE```

When the sequence job runs, it would simply run an update to those records. Then your workflow rule/process builder/trigger would see that the close date is today and the opportunity isn't closed, and then send out the email alert to the owner that they should go and update the opportunity or close it. 

## Functions

There is one function that can be executed out of the box, FieldShift. This allows you to query records and define which fields should be shifted to what value. 

For example, let's say that you want close all opportunities that have not been modified in the last 30 days. You would run a query like this

```SELECT Id FROM Opportunity WHERE IsClosed = false AND LastModifiedDate <= LAST_N_DAYS:30```

Then you would define parameters:

```
StageName:"Closed Lost",
Closed_Lost_Reason__c:"Auto closed"
```

Then when the sequence job is run, all of the opportunities queried would have the **StageName** set to _"Closed Lost"_ and the custom field **Closed_Lost_Reason__c** set to _"Auto Closed"_.

Developers also have the option of creating additional functions that can be used. More details can be found in the "Job Sequencer Help" tab as well as the code comments of the of the "JobSequenceDefaultHandler" class. 

# Managing the Job Sequencer
Assign the **Job Sequencer Admin** permission set to anyone who manages the sequencer. It gives access to the **Job Sequencer** Lightning app and these tabs:

- **Home**: status tiles (sequencer on/off, scheduled frequencies, next run, active jobs, errors in the last 7 days), errors per day, recent runs, recent errors and the jobs that fail most.
- **Job Sequence Scheduler**: shows whether each frequency (every 5 minutes through yearly) is scheduled, with its next and last run, active sequence jobs and recent errors. From here you can schedule, unschedule or run a frequency now.
- **Sequence Jobs**: create, clone, edit, activate, deactivate and reorder Sequence Job records without going into Setup. The editor has a query wizard (object list, a field chooser at the cursor, paste a working query), Test Query, dropdowns for the handler class and its functions, and a Job Parameters builder for FieldShift values and query variables (DateTimeVar or swap-in text), each for scheduled runs or for when Test.isRunningTest() is true.
- **Job Sequence Errors**: what went wrong in each run.
- **Job Sequencer Settings**: the org-wide switch that turns the sequencer on or off, the retry settings, and the run timeout.
- **Job Sequencer Help**: the full guide.

## Running more often than hourly
The Every 5, 10, 15 and 30 Minutes frequencies are scheduled as one Apex job per slot in the hour (a Salesforce schedule can name only one minute), so Every 15 Minutes uses four scheduled jobs and Every 5 Minutes uses twelve. An org can have at most 100 scheduled Apex jobs.

Each run is recorded as a **Job Sequence Run**. A run is skipped while the previous run of the same frequency is still going (the running run's **Times Skipped** is counted), unless that run is older than the **Run Timeout** setting (60 minutes by default).

## Run metrics and cleanup
- Each **Job Sequence Run** records its start, finish and duration, jobs run, records processed and failed, errors logged, and times skipped. Each sequence job in the run gets a **Job Sequence Run Step** with the same metrics, and each **Job Sequence Error** links to its run. Use the **Job Sequence Runs with Steps** report type for your own reports and dashboards.
- **Settings tokens:** a Sequence Job's Select, Where and Parameters can use `{!Settings.FieldName__c}`, which is replaced with that field's value from Sequence Jobs Settings when the query is built.
- **Cleanup on the sequencer itself:** two packaged Daily sequence jobs, `JOBSEQ_PURGE_RUNS` and `JOBSEQ_PURGE_ERRORS`, delete runs and errors older than the **Run History Days** and **Error History Days** settings (30 by default), using settings tokens. They only run when Daily is scheduled; the home page warns when it isn't.

## Upgrading from 1.1.0 or earlier
- The Classic **Job Sequencer** app is replaced by a Lightning app of the same name (API name `Job_Sequencer_App`). Update any profile app assignments or bookmarks that pointed at the old app.
- Frequencies scheduled before 1.2.0 keep running on the original per-frequency classes (e.g. `JobSequenceHourly`), which don't skip a run that is still going. The Scheduler marks them; unschedule and schedule again to switch them over.
- Saving from the **Sequence Jobs** tab needs Customize Application. If a save fails to start in an org that installed the package, enable **Setup > Apex Settings > "Deploy Metadata from Non-Certified Package Versions via Apex"**.

### Check after upgrading (try a sandbox first)
These haven't been verified in an org that installed the package, so check them after the upgrade, ideally in a sandbox before production:

1. **Saving a Sequence Job works.** Open the **Sequence Jobs** tab, edit a job, change something small and save. If the save never starts or fails, turn on the Apex Settings checkbox above and try again.
2. **Your edits to packaged Sequence Job records are kept.** The package ships three Sequence Job records: `TEST_FIELDSHIFT_FUNCTION` (used by the package's tests, so leave it as shipped) and the `JOBSEQ_PURGE_RUNS` / `JOBSEQ_PURGE_ERRORS` cleanup jobs. If you changed any of them, note the values before upgrading and compare afterwards. If the upgrade reset them, re-apply your changes, or clone the job and deactivate the original so later upgrades leave your copy alone.
3. **Scheduled frequencies keep running.** On the **Job Sequence Scheduler** tab, check every frequency you had scheduled is still there with a next run time, and that the next runs show up on the home page.

# Security model
Sequence jobs run in **system mode**. Their queries and DML ignore the running user's object permissions and field-level security, and the framework classes are `without sharing`, so record sharing doesn't limit them either. The original package has always worked this way. From API 67.0, Apex defaults to user mode, so the code marks system mode explicitly to keep that behavior.

What that means for admins:

- **Anyone who can edit Sequence Job records can change or delete any data.** Editing custom metadata needs Customize Application, so control who has that permission.
- **Jobs run as the user who scheduled them.** If that user is deactivated, the scheduled runs stop. The runs also show that user as Last Modified By, and error emails go to them when a job has no notification email. Consider scheduling from a dedicated user that won't be deactivated when someone leaves.
- **Triggers, flows, validation rules and duplicate rules still run** on the records a job changes, and they can still make a job fail.

# Link to Unlocked Package Installer
Job Sequencer is an unlocked package with no namespace (package ID `0HojV0000001HYHSA2`). The latest version is 1.2.0. Installing a newer version over an older one upgrades in place; your Sequence Job records and settings are kept. See [Upgrading from 1.1.0 or earlier](#upgrading-from-110-or-earlier).

| Version | Package version ID | Install | What it added |
| ------- | ------------------ | ------- | ------------- |
| 1.2.0-1 | `04tjV000000AlC9QAK` | [Production / Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tjV000000AlC9QAK) · [Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tjV000000AlC9QAK) | Lightning app with metrics home page, Sequence Jobs tab with query wizard and Job Parameters builder, sub-hourly frequencies, run metrics, settings tokens, cleanup jobs |
| 1.1.0-1 | `04tjV000000AkO9QAK` | [Production / Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tjV000000AkO9QAK) · [Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tjV000000AkO9QAK) | Scheduler and Settings tabs, Job Sequencer Admin permission set, API 68.0 |
| 1.0.0-3 | `04tjV000000AkETQA0` | [Production / Developer Edition](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tjV000000AkETQA0) · [Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tjV000000AkETQA0) | Long Text Area query and parameter fields; ApexDoc |

To install from the CLI: `sf package install --package 04tjV000000AlC9QAK --target-org <alias> --wait 20`
