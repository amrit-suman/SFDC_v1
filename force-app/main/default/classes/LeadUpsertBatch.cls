/**
 * Scenario 1: Upsert 50k leads from external ad system, match on Email,
 * create a follow-up Task for every net-new lead.
 *
 * Architecture:
 *  - External system writes raw rows into Lead_Staging__c (cheap, no trigger overhead).
 *  - This batch reads unprocessed staging rows, bulk-upserts into Lead (by Email),
 *    bulk-inserts Tasks only for isCreated() results, then marks staging rows processed.
 *  - DML count per execute(): 3 statements (upsert + insert + update), well within limits.
 *  - Batch size 100 gives headroom for any Lead trigger DML without hitting 10 k row cap.
 */
global class LeadUpsertBatch implements Database.Batchable<SObject>, Database.Stateful {

    // Stateful counters so finish() can report totals without an extra SOQL
    global Integer totalProcessed = 0;
    global Integer totalCreated   = 0;
    global Integer totalErrors    = 0;

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Email__c, FirstName__c, LastName__c, Company__c,
                   Phone__c, LeadSource__c, Campaign_Name__c
            FROM   Lead_Staging__c
            WHERE  Processed__c = false
            ORDER  BY CreatedDate ASC
        ]);
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Lead_Staging__c> stagingRows  = (List<Lead_Staging__c>) scope;
        List<Lead>            leadsToUpsert = new List<Lead>();

        for (Lead_Staging__c row : stagingRows) {
            leadsToUpsert.add(new Lead(
                Email      = row.Email__c,
                FirstName  = row.FirstName__c,
                LastName   = row.LastName__c,
                Company    = String.isBlank(row.Company__c) ? 'Unknown' : row.Company__c,
                Phone      = row.Phone__c,
                LeadSource = 'Advertisement',
                Description = row.Campaign_Name__c
            ));
        }

        // allOrNone = false → partial success; errors are captured per-row
        Database.UpsertResult[] results = Database.upsert(leadsToUpsert, Lead.Email, false);

        List<Task>            newTasks      = new List<Task>();
        List<Lead_Staging__c> stagingUpdates = new List<Lead_Staging__c>();

        for (Integer i = 0; i < results.size(); i++) {
            Database.UpsertResult ur      = results[i];
            Lead_Staging__c       staging = stagingRows[i];

            staging.Processed__c = true;

            if (ur.isSuccess()) {
                staging.Salesforce_Id__c  = ur.getId();
                staging.Error_Message__c  = null;
                totalProcessed++;

                if (ur.isCreated()) {
                    totalCreated++;
                    newTasks.add(new Task(
                        WhoId        = ur.getId(),
                        Subject      = 'Ad Lead Follow-up',
                        Status       = 'Not Started',
                        Priority     = 'High',
                        ActivityDate = Date.today().addDays(3),
                        Description  = 'Auto-created: new lead from ad campaign integration'
                    ));
                }
            } else {
                totalErrors++;
                staging.Error_Message__c = ur.getErrors()[0].getMessage();
            }

            stagingUpdates.add(staging);
        }

        // Bulk insert tasks (1 DML statement regardless of list size)
        if (!newTasks.isEmpty()) {
            Database.insert(newTasks, false);
        }

        // Mark staging rows processed (success or failure recorded)
        Database.update(stagingUpdates, false);
    }

    global void finish(Database.BatchableContext bc) {
        AsyncApexJob job = [
            SELECT Status, NumberOfErrors, JobItemsProcessed
            FROM   AsyncApexJob
            WHERE  Id = :bc.getJobId()
        ];

        // Replace with Messaging.sendEmail or Platform Event as needed
        System.debug(String.format(
            'LeadUpsertBatch complete — processed: {0}, created: {1}, errors: {2}, job status: {3}',
            new List<Object>{ totalProcessed, totalCreated, totalErrors, job.Status }
        ));
    }
}
