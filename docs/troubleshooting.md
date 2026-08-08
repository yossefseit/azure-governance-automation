# Troubleshooting

## Azure context mismatch

The scripts compare the requested ID with `az account show` and stop. This is a
safety result. Inspect the current context read-only. Do not change subscriptions
automatically, and do not proceed in an employer/customer tenant.

## Local Bicep succeeds but ARM validation fails

Compilation cannot prove provider registration, billing-offer support, permissions,
policy alias behavior, or server-side constraints. Preserve the sanitized Azure
error code and request correlation, check the exact API reference, and correct
the source. Do not label compilation as Azure validation.

## Budget validation fails

Confirm that the subscription offer supports Cost Management budgets, the start
date is the first day of a month in UTC, the amount is positive, and the action
group ID is in the same subscription. The amount uses billing currency. Do not
silently replace a previously deployed budget's stable start date during a rerun,
and do not remove the warning that a budget is not a hard cap.

## Action group exists but no email arrives

The committed example deliberately has zero receivers. Check the private
parameter, action-group receiver status, spam controls, threshold state, and Cost
Management processing delay. Do not spend money merely to fabricate an alert.

## Policy assignment identity cannot remediate

Confirm inheritance is explicitly `Modify`, the assignment has a system identity, the deterministic role assignment
grants built-in Tag Contributor at assignment scope, and identity/RBAC propagation
has completed. Each initiative remediation must specify the exact
`policyDefinitionReferenceId`. Keep tasks disabled until the selected resource
inventory is understood.

## Re-enabling Modify returns RoleAssignmentUpdateNotPermitted

Do not treat `Modify` → `Disabled` → `Modify` as an idempotent toggle. The first
transition removes the policy assignment's system identity, but incremental
deployment can retain the conditional role assignment under its deterministic
name. The second transition creates a different managed-identity principal, and
Azure role-assignment principal/scope properties cannot be updated in place.

Stop rather than changing the GUID formula or broadening permissions. Run the
full guarded cleanup while the manifest is available, verify the stale assignment
is absent, and then deploy the intended state afresh. See Microsoft's
[`RoleAssignmentUpdateNotPermitted` troubleshooting](https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting#symptom---arm-template-role-assignment-returns-badrequest-status).

## Resource remains non-compliant

Check policy evaluation timing, resource tag support, parent resource-group tag
value, initiative parameters, definition reference, and exemption/exclusion state.
The inheritance rule is Disabled by default. Under explicit `Modify`, it only
adds a missing tag and intentionally preserves an explicit resource value.

## Deny blocks an expected service

Return the location or required-tag effect to `Audit` or `Disabled` and redeploy
the same template. Review service location behavior and build a time-bound,
approved exemption process before reintroducing Deny.

## Cleanup stops

Stopping on an unreadable manifest, unexpected ID, wrong marker, failed delete,
or resource-group timeout is intentional. Follow [cleanup recovery](cleanup.md#failure-and-recovery).
Never replace exact IDs with a prefix, wildcard, or subscription-wide delete.

## Lock blocks deletion

`CanNotDelete` inherits to the action group. Delete the exact management-lock ID
first. If removal is denied, obtain the narrow lock-management permission rather
than broad permanent Owner access.
