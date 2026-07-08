// ============================================================
// TEST: Does inserting 201 records fire the trigger once or twice?
//
// SFDC chunks DML in batches of 200 for trigger execution.
// Expected result:
//   Execution #1 -> Trigger.new.size() = 200
//   Execution #2 -> Trigger.new.size() = 2
//   Total executions = 2, Total records = 201
// ============================================================

List<Account> testAccounts = new List<Account>();

for (Integer i = 1; i <= 201; i++) {
    testAccounts.add(new Account(
        Name = 'ChunkTest Account ' + i
    ));
}

System.debug('==== BEFORE INSERT DML ====');
System.debug('Total records being inserted: ' + testAccounts.size());

insert testAccounts;

System.debug('==== AFTER INSERT DML ====');
System.debug('Expected: trigger fired 2 times (chunk 1 = 200 records, chunk 2 = 1 records)');
System.debug('Check TriggerChunkTracker static vars above in logs to confirm.');
