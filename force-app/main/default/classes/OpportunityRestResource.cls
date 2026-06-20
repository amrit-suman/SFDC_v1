/**
 * Scenario 3: REST API — query Opportunities by Account, filter by Stage / CloseDate,
 * return related OpportunityLineItems.
 *
 * URL pattern: /services/apexrest/api/v1/opportunities
 * Query params: accountId (required), stage (optional), closeDateFrom (optional, YYYY-MM-DD)
 *
 * Security:
 *  - "with sharing" enforces row-level sharing rules automatically.
 *  - SOQL bind variables (:var) prevent injection — never concatenate user input into query strings.
 *  - Input is validated before any query runs; 15/18-char ID cast catches malformed IDs.
 *  - The Connected App + OAuth layer handles authentication before this code runs.
 *  - Callers need the "Opportunity: Read" and "Account: Read" object permissions via their profile/permission set.
 *
 * Error contract: always returns JSON with { status, message, data } so callers parse one shape.
 */
@RestResource(urlMapping='/api/v1/opportunities')
global with sharing class OpportunityRestResource {

    // ── GET ───────────────────────────────────────────────────────────────────

    @HttpGet
    global static OpportunityResponse doGet() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        String accountId     = req.params.get('accountId');
        String stage         = req.params.get('stage');
        String closeDateFrom = req.params.get('closeDateFrom');

        // ── Validate required param ───────────────────────────────────────────
        if (String.isBlank(accountId)) {
            res.statusCode = 400;
            return OpportunityResponse.error('accountId query parameter is required');
        }

        // ── Validate ID shape — cast to Id type; throws StringException if malformed ──
        Id safeAccountId;
        try {
            safeAccountId = (Id) accountId;
            // Ensure it references Account, not some other object
            if (safeAccountId.getSObjectType() != Account.SObjectType) {
                res.statusCode = 400;
                return OpportunityResponse.error('accountId must reference an Account record');
            }
        } catch (Exception e) {
            res.statusCode = 400;
            return OpportunityResponse.error('Invalid accountId format');
        }

        // ── Verify the account exists and the caller can see it ───────────────
        if (![SELECT Id FROM Account WHERE Id = :safeAccountId].size() == 0) {
            // Account not visible to this user (sharing) or doesn't exist
            res.statusCode = 404;
            return OpportunityResponse.error('Account not found or not accessible');
        }

        // ── Parse optional closeDate ──────────────────────────────────────────
        Date closeDateFilter;
        if (!String.isBlank(closeDateFrom)) {
            try {
                closeDateFilter = Date.valueOf(closeDateFrom); // expects YYYY-MM-DD
            } catch (Exception e) {
                res.statusCode = 400;
                return OpportunityResponse.error('closeDateFrom must be in YYYY-MM-DD format');
            }
        }

        // ── Build query with bind variables only — no string concatenation ────
        List<Opportunity> opps = queryOpportunities(safeAccountId, stage, closeDateFilter);

        res.statusCode = 200;
        return OpportunityResponse.success(opps);
    }

    // ── Query builder ─────────────────────────────────────────────────────────
    // Kept separate so it stays unit-testable independently of the REST layer.

    @TestVisible
    private static List<Opportunity> queryOpportunities(
        Id    accountId,
        String stage,
        Date  closeDateFilter
    ) {
        // Sub-select for line items; Salesforce will handle null/empty automatically
        String baseQuery =
            'SELECT Id, Name, StageName, CloseDate, Amount, Probability, ' +
            '       Description, AccountId, ' +
            '       (SELECT Id, Name, Quantity, UnitPrice, TotalPrice, Product2.Name ' +
            '        FROM   OpportunityLineItems ' +
            '        ORDER  BY CreatedDate ASC) ' +
            'FROM   Opportunity ' +
            'WHERE  AccountId = :accountId';

        // Append stage filter only when provided; bind variable prevents injection
        if (!String.isBlank(stage)) {
            baseQuery += ' AND StageName = :stage';
        }
        if (closeDateFilter != null) {
            baseQuery += ' AND CloseDate >= :closeDateFilter';
        }

        baseQuery += ' ORDER BY CloseDate ASC NULLS LAST LIMIT 200';

        return Database.query(baseQuery);
    }

    // ── Response wrapper ──────────────────────────────────────────────────────

    global class OpportunityResponse {
        global String            status;
        global String            message;
        global List<Opportunity> data;

        private OpportunityResponse(String status, String message, List<Opportunity> data) {
            this.status  = status;
            this.message = message;
            this.data    = data;
        }

        static OpportunityResponse success(List<Opportunity> data) {
            return new OpportunityResponse('success', null, data);
        }

        static OpportunityResponse error(String message) {
            return new OpportunityResponse('error', message, null);
        }
    }
}
