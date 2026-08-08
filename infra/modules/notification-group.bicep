targetScope = 'resourceGroup'

@description('Name of the Azure Monitor action group.')
param actionGroupName string

@description('Action-group short name; Azure limits this value to 12 characters.')
@minLength(1)
@maxLength(12)
param actionGroupShortName string

@description('Email receivers supplied outside source control. Empty is valid and creates no external notification destination.')
param contactEmails array = []

@description('Tags applied to the action group.')
param tags object

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [for (address, index) in contactEmails: {
      name: 'budget-${index + 1}'
      emailAddress: address
      useCommonAlertSchema: true
    }]
  }
}

output actionGroupResourceId string = actionGroup.id
