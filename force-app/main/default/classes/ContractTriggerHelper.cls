public without sharing class ContractTriggerHelper {
    
    public static void onBeforeUpdate(Map<Id, Contract> newMap, Map<Id, Contract> oldMap){
        validateActivatedContracts(newMap, oldMap);
    }

    public static void validateActivatedContracts(Map<Id, Contract> newMap, Map<Id, Contract> oldMap){

        Set<Id> activatedContractIds = new Set<Id>();
        Set<Id> relatedAccountIds = new Set<Id>();

        for(Contract con : newMap.values()){
            Contract oldCon = oldMap.get(con.Id);
            if(con.Activated && con.Activated != oldCon.Activated && String.isNotBlank(con.AccountId)){
                activatedContractIds.add(con.Id);
                relatedAccountIds.add(con.AccountId);
            }
        }

        if(!activatedContractIds.isEmpty()){
            Set<Id> accountWithProperContracts = new Set<Id>();
            for(AggregateResult agr : [SELECT AccountId, count(Id) counts FROM AccountContactRelation WHERE Role = 'Decision Maker' AND AccountId In :relatedAccountIds GROUP BY AccountId HAVING Count(Id) > 0]){

                accountWithProperContracts.add((Id)agr.get('AccountId'));
            }
            for(Id conId : activatedContractIds){
                if(!accountWithProperContracts.contains(newMap.get(conId).AccountId)){
                    newMap.get(conId).addError('No Proper Contact Found with Role as Decision Maker');
                }
            }
        }
    }
}