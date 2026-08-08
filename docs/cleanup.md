# Cleanup and rollback

## Why cleanup is guarded

The lab creates subscription-level policy, RBAC, remediation, and cost resources
plus a locked resource group. Deleting only the resource group would leave
subscription governance behind. Guessing names or deleting by tag could affect
unrelated resources.

`cleanup.sh` and `Cleanup.ps1` instead read the exact `cleanupManifest` from a
named successful deployment, then require all of these conditions:

- the supplied subscription ID matches the current Azure CLI context;
- the literal confirmation is `DELETE:<deployment-name>`;
- manifest schema and `azure-governance-automation` marker match;
- prefix, resource-group name, resource-provider types, resource names, and
  assignment scopes match the exact IDs derivable from the lab prefix;
- manifest schema 1.2 includes deterministic candidates for optional resources
  and both subscription-scope/three resource-group module deployment names even
  when current creation flags are disabled;
- the governance resource group is read before **any** delete and still has both
  `portfolioLab=azure-governance-automation` and `managedBy=bicep` markers;
- direct resource inventory contains only the manifest action group, lock
  inventory contains only the manifest lock, and subscription RBAC inventory has
  only the exact manifest reviewer assignment at group scope and none below it;
- group deployment history contains only the three deterministic module records;
- immediately before group deletion, the markers are checked again and direct
  resources, locks, and group/descendant RBAC must all be empty.

Any inventory/query failure stops cleanup. The scripts never switch Azure
subscription or tenant. Azure REST calls use relative resource IDs, allowing the
Azure CLI to select the active cloud's Resource Manager endpoint.

The reviewer role-assignment name also depends on `reviewerGroupObjectId`. If
reviewer access has ever been enabled, retain that same object ID privately while
disabling, redeploying, and cleaning up. Replacing it with an empty or different
value makes the earlier deterministic assignment a different address; cleanup
then cannot discover the old assignment from the new deployment manifest.

## Preserve evidence first

Capture only sanitized policy, access, lock, budget, and deployment results before
cleanup. Removing the deployment record also removes the convenient manifest.
Do not commit raw output.

## Run

```bash
./scripts/cleanup.sh \
  --subscription-id "${AZURE_LAB_SUBSCRIPTION_ID}" \
  --deployment-name aglab-governance \
  --confirmation DELETE:aglab-governance
```

PowerShell parity:

```powershell
./scripts/Cleanup.ps1 `
  -SubscriptionId $env:AZURE_LAB_SUBSCRIPTION_ID `
  -DeploymentName aglab-governance `
  -Confirmation 'DELETE:aglab-governance'
```

## Deletion order

1. `CanNotDelete` lock.
2. Optional remediation tasks.
3. Policy assignment.
4. Policy-assignment identity's Tag Contributor role.
5. Initiative.
6. Custom definitions.
7. Subscription budget.
8. Optional reviewer role.
9. Action group by its exact manifest ID.
10. Repeat the fail-closed resource, lock, RBAC, deployment-history, and marker
    inventories; require mutable group contents to be empty.
11. Marked governance resource group and wait for confirmed absence.
12. The two exact subscription module deployment records.
13. Root subscription deployment record last, after its manifest is no longer
    needed.

The script waits up to ten minutes to observe resource-group deletion. A timeout
is a failed teardown result, not permission to claim success.

Before each exact resource delete, the script checks whether the resource still
exists. A verified Azure `404`/`NotFound` is treated as already absent so a partial
cleanup can be rerun while the marked resource group and deployment manifest
still exist. Authentication, network, and other query failures remain hard stops.
Offline Bash and PowerShell tests exercise command failures, malformed/non-array
JSON, duplicates, unexpected resources/locks/RBAC/deployment records, a 403 whose
message contains incidental digits `404`, post-mutation drift, partial states,
and the complete expected delete/wait/deployment-record order with a mock Azure
CLI.

## Failure and recovery

- **Deployment record or manifest missing:** stop. Inventory each expected
  resource read-only and reconstruct a reviewed list; do not modify the script
  to delete by prefix or wildcard.
- **Lock delete fails:** verify the exact ID and lock-management permission. Do
  not attempt resource-group deletion until the lock is confirmed absent.
- **Policy definition still referenced:** find the remaining assignment or
  initiative; do not force or broaden deletion.
- **Resource-group marker differs:** treat it as a possible ownership change and
  stop for manual review.
- **Partial cleanup:** preserve the successful deletion list, re-inventory exact
  IDs, then rerun while the root deployment record still supplies its manifest.
  `az group exists` must return exactly `true` or `false`; query failures or other
  output stop before mutation. If the group is verified absent, the scripts skip
  group-only checks and continue only the exact manifest-bound subscription
  resources and deployment records. This supports a late-stage rerun without
  weakening resource identifiers.
- **Group deleted but deployment-record deletion failed:** rerun while the root
  record still exists. An already absent subscription module record is skipped
  only after a verified `*NotFound`; every other query error stops.
- **`Modify` identity was disabled:** incremental deployment can retain the old
  deterministic role assignment after the system identity is removed. Do not
  re-enable `Modify`; use full guarded cleanup first, then deploy a fresh baseline.
  Otherwise a new principal can collide with the retained role name and return
  `RoleAssignmentUpdateNotPermitted`. See [Azure RBAC troubleshooting](https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting#symptom---arm-template-role-assignment-returns-badrequest-status).

Deleting remediation configuration does not undo tags already written. Restore
changed metadata from an approved inventory if a rollback requires it.
