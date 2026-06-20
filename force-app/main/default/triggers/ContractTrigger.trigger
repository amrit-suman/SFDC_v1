trigger ContractTrigger on Contract (before update) {

    Bypass__c bypass = Bypass__c.getInstance();

    if(bypass.isContractEnabled__c){
        if(Trigger.isBefore){
            if(Trigger.isUpdate()){
                ContractTriggerHelper.onBeforeUpdate(Trigger.newMap, Trigger.oldMap);
            }
        }
    }
}