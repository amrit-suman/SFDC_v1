/**
 * Scenario 4: Batch job that needs HTTP callouts mid-execution.
 *
 * THE CORE RULE:
 *   Batch execute() CAN make callouts if — and only if — the class declares
 *   `implements Database.AllowsCallouts`. Without it, any Http.send() throws
 *   a System.CalloutException at runtime.
 *
 * WHAT "MIDWAY THROUGH" ACTUALLY MEANS:
 *   If the batch is already deployed and RUNNING without Database.AllowsCallouts,
 *   you cannot patch it. Redeploying the class aborts in-flight jobs.
 *   The only escape hatch from a running execute() is System.enqueueJob(),
 *   which enqueues a Queueable in its own transaction with full callout rights.
 *   Limit: ONE System.enqueueJob() call per execute() invocation.
 *
 * TWO PATTERNS SHOWN BELOW:
 *   Pattern A — Correct: batch implements AllowsCallouts, does callout inline.
 *   Pattern B — Workaround: batch without AllowsCallouts offloads callouts to a
 *               chained Queueable from execute(), or collects all IDs and enqueues
 *               one Queueable in finish() to stay under the 1-enqueue-per-execute limit.
 */

// ═══════════════════════════════════════════════════════════════════════════
// Pattern A — ONE bulk callout per execute() chunk (correct approach)
//
// Calling the API once per record inside a for loop is a governor limit trap:
//   - Limit is 100 callouts per transaction.
//   - Default batch size is 200 → blows the limit on record 101.
//   - Even at batch size 100, 100 sequential HTTP round-trips are slow.
// Fix: collect all emails → one bulk POST → map results back by email.
// This costs exactly 1 callout regardless of chunk size.
// ═══════════════════════════════════════════════════════════════════════════
global class LeadEnrichmentBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Email, Company, Enrichment_Status__c
            FROM   Lead
            WHERE  Enrichment_Status__c = 'Pending'
        ]);
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        List<Lead> leads = (List<Lead>) scope;

        // Collect all emails for this chunk
        List<String>        emails        = new List<String>();
        Map<String, Lead>   emailToLead   = new Map<String, Lead>();

        for (Lead lead : leads) {
            if (!String.isBlank(lead.Email)) {
                emails.add(lead.Email);
                emailToLead.put(lead.Email.toLowerCase(), lead);
            }
        }

        if (emails.isEmpty()) return;

        // ONE callout for the entire chunk — bulk endpoint returns a map keyed by email
        Map<String, Map<String, Object>> enrichmentMap = fetchBulkEnrichmentData(emails);
        if (enrichmentMap == null) return;

        List<Lead> toUpdate = new List<Lead>();

        for (String email : enrichmentMap.keySet()) {
            Lead lead = emailToLead.get(email.toLowerCase());
            if (lead == null) continue;

            Map<String, Object> data = enrichmentMap.get(email);
            lead.Company              = (String) data.get('company');
            lead.Industry             = (String) data.get('industry');
            lead.Enrichment_Status__c = 'Enriched';
            toUpdate.add(lead);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    global void finish(Database.BatchableContext bc) {}

    // Sends all emails in one POST; API returns { "results": { "email": { fields } } }
    private static Map<String, Map<String, Object>> fetchBulkEnrichmentData(List<String> emails) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:Enrichment_API/v1/bulk');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000); // bulk call can take longer
            req.setBody(JSON.serialize(new Map<String, Object>{ 'emails' => emails }));

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                return (Map<String, Map<String, Object>>) JSON.deserialize(
                    JSON.serialize(body.get('results')),
                    Map<String, Map<String, Object>>.class
                );
            }
            System.debug(LoggingLevel.WARN, 'Bulk enrichment non-200: ' + res.getStatusCode());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Bulk enrichment callout failed: ' + e.getMessage());
        }
        return null;
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// Pattern B — Workaround when AllowsCallouts was omitted and batch is live
// ═══════════════════════════════════════════════════════════════════════════
global class LeadEnrichmentBatchWorkaround implements Database.Batchable<SObject>, Database.Stateful {

    // Stateful list accumulates all lead IDs across every execute() chunk.
    // One Queueable is enqueued in finish() to keep within the 1-enqueue-per-execute rule.
    @TestVisible
    global List<Id> pendingLeadIds = new List<Id>();

    global Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Email, Enrichment_Status__c
            FROM   Lead
            WHERE  Enrichment_Status__c = 'Pending'
        ]);
    }

    global void execute(Database.BatchableContext bc, List<SObject> scope) {
        // No callout here — just collect IDs
        for (SObject record : scope) {
            pendingLeadIds.add(record.Id);
        }
    }

    global void finish(Database.BatchableContext bc) {
        if (!pendingLeadIds.isEmpty()) {
            // Single enqueue handles ALL leads after the batch completes
            System.enqueueJob(new LeadEnrichmentQueueable(pendingLeadIds));
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// Companion Queueable used by Pattern B (also reusable standalone)
// ═══════════════════════════════════════════════════════════════════════════
public class LeadEnrichmentQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer CHUNK_SIZE = 50; // callouts per Queueable execution

    private final List<Id> leadIds;
    private final Integer  offset;

    public LeadEnrichmentQueueable(List<Id> leadIds) {
        this(leadIds, 0);
    }

    private LeadEnrichmentQueueable(List<Id> leadIds, Integer offset) {
        this.leadIds = leadIds;
        this.offset  = offset;
    }

    public void execute(QueueableContext ctx) {
        // Process this chunk
        Integer end  = Math.min(offset + CHUNK_SIZE, leadIds.size());
        List<Id> chunk = new List<Id>();
        for (Integer i = offset; i < end; i++) {
            chunk.add(leadIds[i]);
        }

        List<Lead> leads    = [SELECT Id, Email FROM Lead WHERE Id IN :chunk];
        List<Lead> toUpdate = new List<Lead>();

        for (Lead lead : leads) {
            Map<String, Object> enriched = fetchEnrichmentData(lead.Email);
            if (enriched == null) continue;

            lead.Company              = (String) enriched.get('company');
            lead.Industry             = (String) enriched.get('industry');
            lead.Enrichment_Status__c = 'Enriched';
            toUpdate.add(lead);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }

        // Chain next Queueable for remaining records (self-chaining)
        if (end < leadIds.size()) {
            System.enqueueJob(new LeadEnrichmentQueueable(leadIds, end));
        }
    }

    private static Map<String, Object> fetchEnrichmentData(String email) {
        if (String.isBlank(email)) return null;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:Enrichment_API/v1/person?email='
                            + EncodingUtil.urlEncode(email, 'UTF-8'));
            req.setMethod('GET');
            req.setTimeout(10000);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Enrichment callout failed for ' + email + ': ' + e.getMessage());
        }
        return null;
    }
}
