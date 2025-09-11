@isTest
private class RazorpayWebhookTest {


@IsTest
    static void testPaymentCapturedWebhook() {
        // Create a test Payment__c record
        Payment__c testPayment = new Payment__c(Razorpay_ID__c = 'test_order_id', Status__c = 'Pending');
        insert testPayment;

        // Create a mock webhook payload
        Map<String, Object> payload = new Map<String, Object>{
            'event' => 'payment.captured',
            'payload' => new Map<String, Object>{
                'payment' => new Map<String, Object>{
                    'entity' => new Map<String, Object>{
                        'order_id' => 'test_order_id',
                        'id' => 'test_payment_id',
                        'status' => 'captured'
                    }
                }
            }
        };

        // Set up the mock request
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/webhooks/razorpay';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(payload));
        RestContext.request = req;

        // Call the webhook handler
        Test.startTest();
        RazorpayWebhook.handleWebhook();
        Test.stopTest();

        // Verify that the Payment__c record was updated
        Payment__c updatedPayment = [SELECT Id, Status__c FROM Payment__c WHERE Id = :testPayment.Id];
        System.assertEquals('Paid', updatedPayment.Status__c, 'Payment status should be updated to "Paid"');
    }

}