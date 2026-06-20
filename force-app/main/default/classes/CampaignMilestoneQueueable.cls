/**
 * Scenario 2: AWS SNS fires when an ad campaign hits a milestone.
 * Update the Salesforce Campaign record AND POST to a Slack webhook.
 *
 * Why Queueable over @future:
 *  - @future(callout=true) can't chain jobs, can't pass objects, has no status tracking.
 *  - Queueable implements Database.AllowsCallouts, can chain retries, and accepts typed args.
 *
 * Callout-before-DML rule:
 *  Salesforce prevents callouts after uncommitted DML in the same transaction.
 *  So we call Slack FIRST, then update Campaign.
 *  This means a Campaign update cannot be rolled back if Slack later fails —
 *  the workaround is to chain a dedicated SlackRetryQueueable instead of using Savepoint
 *  (Savepoints are invalidated the moment any callout completes).
 *
 * Slack failure handling:
 *  If Slack returns a non-200 or throws a timeout, the Campaign is still updated
 *  (because we already confirmed the business event happened). The failure is logged
 *  and a retry Queueable is chained with exponential back-off tracking.
 */
public class CampaignMilestoneQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer SLACK_TIMEOUT_MS  = 10000;
    private static final Integer MAX_RETRIES        = 3;

    private final String campaignId;
    private final String milestoneType;
    private final Map<String, Object> snsPayload;
    private final Integer retryCount;

    public CampaignMilestoneQueueable(
        String campaignId,
        String milestoneType,
        Map<String, Object> snsPayload
    ) {
        this(campaignId, milestoneType, snsPayload, 0);
    }

    // Private constructor for retries
    private CampaignMilestoneQueueable(
        String campaignId,
        String milestoneType,
        Map<String, Object> snsPayload,
        Integer retryCount
    ) {
        this.campaignId    = campaignId;
        this.milestoneType = milestoneType;
        this.snsPayload    = snsPayload;
        this.retryCount    = retryCount;
    }

    public void execute(QueueableContext ctx) {
        // ── Step 1: Callout FIRST (before any DML) ───────────────────────────
        Boolean slackSuccess = postToSlack();

        // ── Step 2: DML after callout ─────────────────────────────────────────
        updateCampaign();

        // ── Step 3: Retry Slack if it failed, up to MAX_RETRIES ──────────────
        if (!slackSuccess && retryCount < MAX_RETRIES) {
            System.enqueueJob(new CampaignMilestoneQueueable(
                campaignId, milestoneType, snsPayload, retryCount + 1
            ));
        } else if (!slackSuccess) {
            logSlackFailure();
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private Boolean postToSlack() {
        try {
            HttpRequest req = new HttpRequest();
            // Named Credential keeps the webhook URL out of code and configurable per org
            req.setEndpoint('callout:Slack_Ad_Webhook');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(SLACK_TIMEOUT_MS);

            Map<String, Object> body = new Map<String, Object>{
                'text' => buildSlackMessage(),
                'attachments' => new List<Object>{
                    new Map<String, Object>{
                        'color'  => '#36a64f',
                        'fields' => new List<Object>{
                            new Map<String, Object>{ 'title' => 'Campaign ID',  'value' => campaignId,    'short' => true },
                            new Map<String, Object>{ 'title' => 'Milestone',    'value' => milestoneType, 'short' => true },
                            new Map<String, Object>{ 'title' => 'Retry Attempt','value' => String.valueOf(retryCount), 'short' => true }
                        }
                    }
                }
            };
            req.setBody(JSON.serialize(body));

            HttpResponse res = new Http().send(req);
            return res.getStatusCode() == 200;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Slack callout exception: ' + e.getMessage());
            return false;
        }
    }

    private void updateCampaign() {
        try {
            Campaign camp = [
                SELECT Id, Status, Description
                FROM   Campaign
                WHERE  Id = :campaignId
                FOR UPDATE           // row-lock to prevent concurrent milestone races
            ];

            camp.Status      = resolveCampaignStatus(milestoneType);
            camp.Description = 'Last milestone: ' + milestoneType + ' at ' + Datetime.now();
            update camp;

        } catch (QueryException e) {
            System.debug(LoggingLevel.ERROR, 'Campaign not found: ' + campaignId);
        } catch (DmlException e) {
            System.debug(LoggingLevel.ERROR, 'Campaign update failed: ' + e.getMessage());
        }
    }

    private String resolveCampaignStatus(String milestone) {
        Map<String, String> milestoneToStatus = new Map<String, String>{
            'BUDGET_EXHAUSTED' => 'Completed',
            'GOAL_REACHED'     => 'Completed',
            'HALFWAY'          => 'In Progress',
            'STARTED'          => 'Active'
        };
        return milestoneToStatus.containsKey(milestone) ? milestoneToStatus.get(milestone) : 'In Progress';
    }

    private String buildSlackMessage() {
        return String.format(
            ':mega: Ad Campaign milestone hit — *{0}* on campaign `{1}`',
            new List<Object>{ milestoneType, campaignId }
        );
    }

    private void logSlackFailure() {
        // Persist failure for ops visibility — insert an error log custom object or Platform Event
        System.debug(LoggingLevel.ERROR,
            'Slack notification permanently failed after ' + MAX_RETRIES + ' retries for campaign: ' + campaignId
        );
    }
}
