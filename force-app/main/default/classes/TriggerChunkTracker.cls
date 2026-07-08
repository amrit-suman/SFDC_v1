public class TriggerChunkTracker {
    // Static variables persist across ALL trigger executions within one transaction
    // This is what lets us count how many times the trigger fires
    public static Integer executionCount = 0;
    public static Integer totalRecordsProcessed = 0;
}