# Deployment runbook

## Evidence status

No command in this runbook has been run against Azure for this repository. Local
Bicep lint/build is complete; authenticated validation, what-if, deployment, and
teardown are pending.

## Prerequisites

- A personally owned Azure tenant and subscription whose billing ownership is
  unambiguous. Stop if the context is employer/customer owned or uncertain.
- Azure CLI authenticated to the intended subscription. The scripts inspect but
  never change the context.
- Bicep CLI 0.46.1 or an Azure CLI capable of installing/running that version.
- `jq` for Bash cleanup; PowerShell 7 for the PowerShell path.
- Permission to validate subscription deployments and, for deployment, manage
  the resource types and role assignments listed in [access model](access-model.md).
- Explicit cost approval despite the absence of workload resources.

Provider registration and billing-offer support must be checked in the target
subscription. Validation can fail without changing resources; do not respond by
silently switching subscriptions or granting Owner permanently.

## 1. Create a private parameter file

```bash
cp infra/environments/lab.example.bicepparam \
  infra/environments/lab.local.bicepparam
```

The `*.local.bicepparam` pattern is ignored. Review:

- prefix and region list;
- budget amount **and target billing currency**;
- budget start date set to an approved first day of a UTC month and retained
  unchanged for every rerun of that same budget;
- one monitored notification address, if approved;
- Audit effects;
- inheritance and remediation disabled;
- optional Reader disabled unless a real group is approved; if it was enabled
  previously, retain the same private group object ID until cleanup;
- lock enabled.

Never add a tenant ID, subscription ID, person object ID, or email address to the
committed example.

The committed budget date is a stable compile-only example, not a timeless live
default. Before the first deployment, choose a date accepted for the current
billing period in the target subscription. Keep that exact date in the ignored
local parameter file for same-parameter reruns; changing it is an explicit
budget lifecycle decision.

## 2. Confirm context read-only

```bash
az account show --output table
```

If ownership is uncertain, stop. The scripts require the target ID on every call
and compare it to `az account show`. They do not contain or call a subscription
context-switch operation.

## 3. Local checks

```bash
BICEP_BIN=/path/to/bicep bash tests/run.sh
```

## 4. Authenticated ARM validation

```bash
./scripts/validate.sh \
  --subscription-id "${AZURE_LAB_SUBSCRIPTION_ID}" \
  --location westeurope \
  --parameters infra/environments/lab.local.bicepparam
```

PowerShell parity:

```powershell
./scripts/Validate.ps1 `
  -SubscriptionId $env:AZURE_LAB_SUBSCRIPTION_ID `
  -Location westeurope `
  -ParametersFile infra/environments/lab.local.bicepparam
```

Record only a sanitized success/failure result. ARM validation is not deployment.

## 5. Review what-if

```bash
./scripts/what-if.sh \
  --subscription-id "${AZURE_LAB_SUBSCRIPTION_ID}" \
  --location westeurope \
  --parameters infra/environments/lab.local.bicepparam
```

Inspect every create/modify/delete, policy scope, role definition ID, principal,
budget threshold, receiver, lock, and remediation condition. What-if has
[documented limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if);
it is not proof of runtime behavior.

## 6. Deploy only after approval

The deploy wrapper repeats authenticated ARM validation and a full-resource
what-if immediately before it asks for the final confirmation. A confirmation
cannot be supplied ahead of those gates. Review their live output, then type the
exact phrase at the prompt.

```bash
./scripts/deploy.sh \
  --subscription-id "${AZURE_LAB_SUBSCRIPTION_ID}" \
  --location westeurope \
  --deployment-name aglab-governance \
  --parameters infra/environments/lab.local.bicepparam
```

PowerShell uses the same literal confirmation:

```powershell
./scripts/Deploy.ps1 `
  -SubscriptionId $env:AZURE_LAB_SUBSCRIPTION_ID `
  -Location westeurope `
  -DeploymentName aglab-governance `
  -ParametersFile infra/environments/lab.local.bicepparam
```

Both paths prompt for `DEPLOY:aglab-governance` only after validation and what-if
return successfully. EOF, an incorrect phrase, validation failure, or what-if
failure stops before `create`.

Do not enable inheritance or remediation in the first deployment. Enabling
`Modify` creates a system identity and subscription-scope Tag Contributor
assignment. Wait for policy/RBAC propagation before a separately approved
remediation run, then follow [validation](validation.md).

Keep `inheritancePolicyEffect` stable on subsequent deployments. If `Modify` has
ever been deployed, do not use `Modify` → `Disabled` → `Modify` as an idempotency
test. Disabling removes the policy assignment's system identity, while incremental
deployment can retain its deterministic role assignment. Re-enabling can create
a new principal that cannot update the existing assignment and returns
`RoleAssignmentUpdateNotPermitted`. Run full guarded cleanup before switching
away from `Modify`, then deploy the desired state afresh. Microsoft documents the
[immutable role-assignment property failure](https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting#symptom---arm-template-role-assignment-returns-badrequest-status).

## Rollback before cleanup

For an unexpected Audit/Deny effect, set required-tag and location effects to
`Disabled` (or `Audit`) and redeploy. Incremental deployment does not delete a
previously created conditional lock, remediation task, or role assignment when
its creation flag becomes false. Manifest schema 1.2 therefore keeps their
deterministic cleanup candidates and nested deployment names present while
disabled. If reviewer access was ever enabled, retain its original private group
object ID because that value is part of the role-assignment name. Run full
guarded cleanup before changing that ID or losing the successful deployment
record. Full cleanup is also required before changing away from `Modify`; do not
later re-enable it over a retained role assignment. Disabling policy does not
undo tags already changed by remediation.

The complete cleanup order is in [cleanup](cleanup.md).
