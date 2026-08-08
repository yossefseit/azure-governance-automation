targetScope = 'subscription'

@description('Subscription budget name.')
param budgetName string

@description('Monthly alert threshold in the subscription billing currency.')
@minValue(1)
param amount int

@description('First day of the budget period in UTC.')
param startDate string

@description('Resource ID of the action group that receives budget notifications.')
param actionGroupResourceId string

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      Actual80Percent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: []
        contactGroups: [
          actionGroupResourceId
        ]
        contactRoles: []
        locale: 'en-us'
      }
      Forecast100Percent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: []
        contactGroups: [
          actionGroupResourceId
        ]
        contactRoles: []
        locale: 'en-us'
      }
    }
  }
}

output budgetResourceId string = budget.id
