# Cost and guardrails

## Cost posture

The template creates governance control-plane configuration and no workload
compute, disk, gateway, database, cluster, or data-ingestion resource. It is
therefore designed for no steady-state workload runtime. That is not a guarantee
of a 0 EGP invoice.

Possible cost variables still include:

- the target subscription offer and billing currency;
- action-group notification type and volume;
- unrelated resources already in the subscription;
- future policy remediation deployments;
- future services added to the same resource group or subscription;
- Azure pricing changes.

Verify the current terms in the [Azure pricing documentation](https://azure.microsoft.com/en-us/pricing/)
and the [Azure Monitor pricing page](https://azure.microsoft.com/en-us/pricing/details/monitor/)
before deployment. No live price, bill, notification charge, or zero-cost result
has been verified for this repository.

## Budget behavior

`monthlyBudgetAmount` is expressed in the billing currency of the subscription,
not necessarily EGP. Its committed example value is not a spend approval.
`budgetStartDate` is required by the template: select an approved first-of-month
UTC date in the private parameter file, then retain it across reruns so deployment
does not drift with the workstation date. The two notifications are:

| Trigger | Type | Purpose |
| --- | --- | --- |
| 80 percent | Actual | Early warning after recorded cost reaches the threshold |
| 100 percent | Forecasted | Warning that forecast cost meets/exceeds the threshold |

Cost data and notifications can be delayed. Budgets do not stop deployments,
deallocate resources, enforce quota, reserve funds, or create a hard cap. See
[Create and manage Azure budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets).

The committed parameter file intentionally has no email receiver. A deployment
with that file creates the action group wiring but has no external email
destination. Before a real deployment, add a monitored address only to an ignored
local parameter file and verify delivery separately.

## Zero-budget operating rule

For a 0 EGP portfolio budget:

1. Do not deploy without explicit personal-subscription ownership and cost
   approval, even if the template appears free.
2. Inventory existing subscription resources before and after the change.
3. Keep policy effects on Audit until compliance is understood.
4. Keep inheritance and remediation disabled until scope, RBAC, and a bounded
   resource inventory are reviewed.
5. Capture the target billing currency and current pricing as private evidence.
6. Run cleanup and confirm resource-group deletion when evidence collection ends.
7. Review the Azure bill later; immediate teardown is not proof of zero cost.

The lock deliberately makes deletion a two-step operation. It is a safety control,
but it can also prolong resource lifetime when cleanup is incomplete.
