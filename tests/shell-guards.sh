#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${TEST_DIR}/.." && pwd)"
TEST_TEMP_DIR="$(mktemp -d)"
trap 'rm -r -- "${TEST_TEMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

matching_subscription_id="$(printf '%08x-%04x-%04x-%04x-%012x' 1 2 3 4 5)"
different_subscription_id="$(printf '%08x-%04x-%04x-%04x-%012x' 6 7 8 9 10)"
mock_log="${TEST_TEMP_DIR}/az.log"
mock_state="${TEST_TEMP_DIR}/state"
touch "${mock_log}"
export PATH="${TEST_DIR}/fixtures:${PATH}"
export MOCK_AZ_LOG="${mock_log}"
export MOCK_AZ_STATE_DIR="${mock_state}"
export MOCK_SUBSCRIPTION_ID="${matching_subscription_id}"

expect_failure() {
  local expected_text="$1"
  shift
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ ${status} -ne 0 ]] || fail "Command unexpectedly succeeded: $*"
  [[ ${output} == *"${expected_text}"* ]] || fail "Expected '${expected_text}' in output: ${output}"
}

assert_no_cleanup_mutation() {
  if grep -Eq 'deployment sub delete|group delete|rest --method delete' "${mock_log}"; then
    fail 'A failure-guard scenario reached an Azure mutation command.'
  fi
}

reset_scenario() {
  : >"${mock_log}"
  rm -r -- "${mock_state}" 2>/dev/null || true
  mkdir -p -- "${mock_state}"
  unset MOCK_INVENTORY_FAILURE MOCK_FINAL_DIRECT_RESOURCES_JSON MOCK_FINAL_LOCKS_JSON
  unset MOCK_FINAL_ROLE_ASSIGNMENTS_JSON MOCK_FINAL_ACTION_GROUP_ROLE_ASSIGNMENTS_JSON
  unset MOCK_FINAL_GROUP_DEPLOYMENTS_JSON MOCK_FINAL_RESOURCE_GROUP_JSON
  unset MOCK_GROUP_EXISTS_FAILURE MOCK_REST_GET_MODE
  export MOCK_GROUP_EXISTS_OUTPUT=true
  export MOCK_RESOURCE_GROUP_JSON="${correct_resource_group_json}"
  MOCK_DIRECT_RESOURCES_JSON="$(jq -cn --arg id "${action_group_id}" '[$id]')"
  export MOCK_DIRECT_RESOURCES_JSON
  MOCK_LOCKS_JSON="$(jq -cn --arg id "${lock_id}" '[$id]')"
  export MOCK_LOCKS_JSON
  MOCK_ROLE_ASSIGNMENTS_JSON="$(jq -cn \
    --arg id "${reviewer_role_id}" \
    --arg scope "${resource_group_id}" \
    --arg role "${reader_role_id}" \
    --arg principal "${reviewer_principal_id}" \
    '[{id: $id, scope: $scope, roleDefinitionId: $role, principalId: $principal}]')"
  export MOCK_ROLE_ASSIGNMENTS_JSON
  export MOCK_ACTION_GROUP_ROLE_ASSIGNMENTS_JSON='[]'
  MOCK_GROUP_DEPLOYMENTS_JSON="$(jq -cn \
    --arg notification aglab-notification-group \
    --arg reviewer aglab-reviewer-access \
    --arg lock aglab-resource-lock \
    '[$notification, $reviewer, $lock]')"
  export MOCK_GROUP_DEPLOYMENTS_JSON
  export MOCK_ABSENT_RESOURCE_IDS_JSON='[]'
}

run_cleanup() {
  "${REPOSITORY_ROOT}/scripts/cleanup.sh" \
    --subscription-id "${matching_subscription_id}" \
    --deployment-name aglab-governance \
    --confirmation DELETE:aglab-governance
}

expect_cleanup_failure() {
  local expected_text="$1"
  expect_failure "${expected_text}" run_cleanup
}

# Context and confirmation guards do not need a deployment fixture.
expect_failure 'Azure context mismatch' \
  "${REPOSITORY_ROOT}/scripts/validate.sh" --subscription-id "${different_subscription_id}"
expect_failure 'Azure context mismatch' \
  "${REPOSITORY_ROOT}/scripts/what-if.sh" --subscription-id "${different_subscription_id}"
expect_failure 'final interactive confirmation was not provided' \
  "${REPOSITORY_ROOT}/scripts/deploy.sh" --subscription-id "${matching_subscription_id}"
expect_failure 'Cleanup stopped' \
  "${REPOSITORY_ROOT}/scripts/cleanup.sh" --subscription-id "${matching_subscription_id}"

subscription_base="/subscriptions/${matching_subscription_id}"
resource_group_name='rg-aglab-governance'
resource_group_id="${subscription_base}/resourceGroups/${resource_group_name}"
lock_id="${resource_group_id}/providers/Microsoft.Authorization/locks/aglab-delete-protection"
action_group_id="${resource_group_id}/providers/Microsoft.Insights/actionGroups/ag-aglab-cost"
budget_id="${subscription_base}/providers/Microsoft.Consumption/budgets/aglab-monthly-guardrail"
policy_assignment_id="${subscription_base}/providers/Microsoft.Authorization/policyAssignments/aglab-guardrails"
policy_set_id="${subscription_base}/providers/Microsoft.Authorization/policySetDefinitions/aglab-baseline"
policy_inherit_id="${subscription_base}/providers/Microsoft.Authorization/policyDefinitions/aglab-inherit-rg-tag"
policy_required_id="${subscription_base}/providers/Microsoft.Authorization/policyDefinitions/aglab-require-rg-tag"
policy_locations_id="${subscription_base}/providers/Microsoft.Authorization/policyDefinitions/aglab-allowed-locations"
remediation_role_guid="$(printf '%08x-%04x-%04x-%04x-%012x' 11 12 13 14 15)"
reviewer_role_guid="$(printf '%08x-%04x-%04x-%04x-%012x' 16 17 18 19 20)"
reviewer_principal_id="$(printf '%08x-%04x-%04x-%04x-%012x' 21 22 23 24 25)"
remediation_role_id="${subscription_base}/providers/Microsoft.Authorization/roleAssignments/${remediation_role_guid}"
reviewer_role_id="${resource_group_id}/providers/Microsoft.Authorization/roleAssignments/${reviewer_role_guid}"
reader_role_id="${subscription_base}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
remediation_environment_id="${subscription_base}/providers/Microsoft.PolicyInsights/remediations/aglab-remediate-environment"
remediation_owner_id="${subscription_base}/providers/Microsoft.PolicyInsights/remediations/aglab-remediate-owner"
subscription_budget_deployment_id="${subscription_base}/providers/Microsoft.Resources/deployments/aglab-subscription-budget"
policy_governance_deployment_id="${subscription_base}/providers/Microsoft.Resources/deployments/aglab-policy-governance"

MOCK_MANIFEST_JSON="$(jq -cn \
  --arg resource_group_name "${resource_group_name}" \
  --arg lock "${lock_id}" \
  --arg action_group "${action_group_id}" \
  --arg budget "${budget_id}" \
  --arg reviewer_role "${reviewer_role_id}" \
  --arg assignment "${policy_assignment_id}" \
  --arg remediation_role "${remediation_role_id}" \
  --arg initiative "${policy_set_id}" \
  --arg inherit "${policy_inherit_id}" \
  --arg required "${policy_required_id}" \
  --arg locations "${policy_locations_id}" \
  --arg remediation_environment "${remediation_environment_id}" \
  --arg remediation_owner "${remediation_owner_id}" '
    {
      schemaVersion: "1.2",
      labMarker: "azure-governance-automation",
      prefix: "aglab",
      governanceResourceGroupName: $resource_group_name,
      deploymentNames: {
        subscriptionModules: ["aglab-subscription-budget", "aglab-policy-governance"],
        resourceGroupModules: ["aglab-notification-group", "aglab-reviewer-access", "aglab-resource-lock"]
      },
      resourceIds: {
        lock: $lock,
        actionGroup: $action_group,
        budget: $budget,
        reviewerRoleAssignment: $reviewer_role,
        policyAssignment: $assignment,
        remediationRoleAssignment: $remediation_role,
        policySetDefinition: $initiative,
        policyDefinitions: [$inherit, $required, $locations],
        remediations: [$remediation_environment, $remediation_owner]
      }
    }
  ')"
export MOCK_MANIFEST_JSON
export MOCK_ACTION_GROUP_ID="${action_group_id}"
export MOCK_REMEDIATION_ROLE_ID="${remediation_role_id}"
export MOCK_REVIEWER_ROLE_ID="${reviewer_role_id}"
MOCK_REMEDIATION_ROLE_JSON="$(jq -cn \
  --arg scope "${subscription_base}" \
  --arg role "${subscription_base}/providers/Microsoft.Authorization/roleDefinitions/4a9ae827-6dc8-4573-8ac7-8239d42aa03f" '
    {properties: {
      scope: $scope,
      roleDefinitionId: $role,
      principalType: "ServicePrincipal",
      description: "Allows only the policy assignment managed identity to remediate resource tags at assignment scope."
    }}
  ')"
MOCK_REVIEWER_ROLE_JSON="$(jq -cn \
  --arg scope "${resource_group_id}" \
  --arg role "${reader_role_id}" '
    {properties: {
      scope: $scope,
      roleDefinitionId: $role,
      principalType: "Group",
      description: "Read-only access to the governance lab resource group."
    }}
  ')"
export MOCK_REMEDIATION_ROLE_JSON MOCK_REVIEWER_ROLE_JSON

correct_resource_group_json="$(jq -cn --arg id "${resource_group_id}" \
  '{id: $id, tags: {portfolioLab: "azure-governance-automation", managedBy: "bicep"}}')"

# Wrong ownership, existence-query errors, and invalid booleans stop before mutation.
reset_scenario
MOCK_RESOURCE_GROUP_JSON="$(jq -cn --arg id "${resource_group_id}" \
  '{id: $id, tags: {portfolioLab: "wrong-marker", managedBy: "bicep"}}')"
export MOCK_RESOURCE_GROUP_JSON
expect_cleanup_failure 'safety markers do not match'
assert_no_cleanup_mutation

for existence_mode in error invalid; do
  reset_scenario
  if [[ ${existence_mode} == error ]]; then
    export MOCK_GROUP_EXISTS_FAILURE=true
    expected='Could not determine whether'
  else
    export MOCK_GROUP_EXISTS_OUTPUT='not-a-boolean'
    expected='existence inventory returned an invalid value'
  fi
  expect_cleanup_failure "${expected}"
  assert_no_cleanup_mutation
done

# Every RG inventory command fails closed before the first mutation.
for inventory_kind in resource lock role deployment; do
  reset_scenario
  export MOCK_INVENTORY_FAILURE="${inventory_kind}"
  expect_cleanup_failure 'Could not inventory'
  assert_no_cleanup_mutation
done

# Malformed, non-array, duplicate, and unexpected inventory results are rejected.
reset_scenario
export MOCK_DIRECT_RESOURCES_JSON='not-json'
expect_cleanup_failure 'not a valid string array'
assert_no_cleanup_mutation

reset_scenario
export MOCK_LOCKS_JSON='{}'
expect_cleanup_failure 'not a valid string array'
assert_no_cleanup_mutation

reset_scenario
MOCK_DIRECT_RESOURCES_JSON="$(jq -cn --arg id "${action_group_id}" '[$id, $id]')"
export MOCK_DIRECT_RESOURCES_JSON
expect_cleanup_failure 'duplicate item'
assert_no_cleanup_mutation

reset_scenario
MOCK_ROLE_ASSIGNMENTS_JSON="$(jq -cn \
  --arg id "${reviewer_role_id}" --arg scope "${resource_group_id}" \
  --arg role "${reader_role_id}" --arg principal "${reviewer_principal_id}" \
  '[{id: $id, scope: $scope, roleDefinitionId: $role, principalId: $principal},
    {id: $id, scope: $scope, roleDefinitionId: $role, principalId: $principal}]')"
export MOCK_ROLE_ASSIGNMENTS_JSON
expect_cleanup_failure 'duplicate item'
assert_no_cleanup_mutation

reset_scenario
export MOCK_GROUP_DEPLOYMENTS_JSON='["aglab-notification-group","aglab-notification-group"]'
expect_cleanup_failure 'duplicate item'
assert_no_cleanup_mutation

unexpected_resource_id="${resource_group_id}/providers/Microsoft.Storage/storageAccounts/unexpected"
reset_scenario
MOCK_DIRECT_RESOURCES_JSON="$(jq -cn --arg expected "${action_group_id}" --arg extra "${unexpected_resource_id}" '[$expected, $extra]')"
export MOCK_DIRECT_RESOURCES_JSON
expect_cleanup_failure 'Direct resource-group resource inventory contains an unexpected item'
assert_no_cleanup_mutation

reset_scenario
MOCK_LOCKS_JSON="$(jq -cn --arg expected "${lock_id}" --arg extra "${resource_group_id}/providers/Microsoft.Authorization/locks/unexpected" '[$expected, $extra]')"
export MOCK_LOCKS_JSON
expect_cleanup_failure 'Resource-group lock inventory contains an unexpected item'
assert_no_cleanup_mutation

reset_scenario
MOCK_ROLE_ASSIGNMENTS_JSON="$(jq -cn \
  --arg scope "${resource_group_id}" --arg role "${reader_role_id}" \
  --arg principal "${reviewer_principal_id}" \
  '[{id: ($scope + "/providers/Microsoft.Authorization/roleAssignments/unexpected"), scope: $scope, roleDefinitionId: $role, principalId: $principal}]')"
export MOCK_ROLE_ASSIGNMENTS_JSON
expect_cleanup_failure 'unexpected exact-scope assignment'
assert_no_cleanup_mutation

reset_scenario
MOCK_ROLE_ASSIGNMENTS_JSON="$(jq -cn \
  --arg id "${reviewer_role_id}" --arg scope "${action_group_id}" \
  --arg role "${reader_role_id}" --arg principal "${reviewer_principal_id}" \
  '[{id: $id, scope: $scope, roleDefinitionId: $role, principalId: $principal}]')"
export MOCK_ROLE_ASSIGNMENTS_JSON
expect_cleanup_failure 'unexpected descendant-scope assignment'
assert_no_cleanup_mutation

reset_scenario
export MOCK_GROUP_DEPLOYMENTS_JSON='["aglab-notification-group","unexpected-module"]'
expect_cleanup_failure 'Resource-group deployment record inventory contains an unexpected item'
assert_no_cleanup_mutation

# A non-404 error containing incidental digits 404 must not be treated as absent.
reset_scenario
export MOCK_REST_GET_MODE='error-with-incidental-404'
expect_cleanup_failure 'Could not verify resource state before deletion'
assert_no_cleanup_mutation

# Final inventory catches drift introduced after exact deletes and blocks group deletion.
reset_scenario
MOCK_FINAL_DIRECT_RESOURCES_JSON="$(jq -cn --arg id "${unexpected_resource_id}" '[$id]')"
export MOCK_FINAL_DIRECT_RESOURCES_JSON
expect_cleanup_failure 'Direct resource-group resource inventory is not empty'
grep -Fq 'rest --method delete' "${mock_log}" || fail 'Final-drift test never reached the post-mutation recheck.'
if grep -Eq '^group delete' "${mock_log}"; then fail 'Final drift did not block resource-group deletion.'; fi

# Mixed-case expected inventories are accepted; all exact mutations follow the reviewed order.
reset_scenario
MOCK_DIRECT_RESOURCES_JSON="$(jq -cn --arg id "${action_group_id^^}" '[$id]')"
export MOCK_DIRECT_RESOURCES_JSON
MOCK_LOCKS_JSON="$(jq -cn --arg id "${lock_id^^}" '[$id]')"
export MOCK_LOCKS_JSON
MOCK_ROLE_ASSIGNMENTS_JSON="$(jq -cn \
  --arg id "${reviewer_role_id^^}" --arg scope "${resource_group_id^^}" \
  --arg role "${reader_role_id^^}" --arg principal "${reviewer_principal_id}" \
  '[{id: $id, scope: $scope, roleDefinitionId: $role, principalId: $principal}]')"
export MOCK_ROLE_ASSIGNMENTS_JSON
export MOCK_GROUP_DEPLOYMENTS_JSON='["AGLAB-NOTIFICATION-GROUP","AGLAB-REVIEWER-ACCESS","AGLAB-RESOURCE-LOCK"]'
cleanup_output="$(run_cleanup 2>&1)" || fail "Complete cleanup mock failed: ${cleanup_output}"
[[ ${cleanup_output} == *'governance resource group is absent'* ]] || \
  fail "Complete cleanup mock did not report success: ${cleanup_output}"

[[ $(grep -c '^resource list ' "${mock_log}") -eq 2 ]] || fail 'Direct resources were not inventoried twice.'
[[ $(grep -c '^lock list ' "${mock_log}") -eq 2 ]] || fail 'Locks were not inventoried twice.'
[[ $(grep -c '^role assignment list .*--all ' "${mock_log}") -eq 2 ]] || fail 'Subscription roles were not inventoried twice.'
[[ $(grep -c '^deployment group list ' "${mock_log}") -eq 2 ]] || fail 'RG deployments were not inventoried twice.'
[[ $(grep -c '^group show ' "${mock_log}") -eq 2 ]] || fail 'RG markers were not validated twice.'

mapfile -t mutation_log < <(grep -E '^(rest --method delete|group delete|group wait|deployment sub delete)' "${mock_log}")
expected_mutations=(
  "rest --method delete --url ${lock_id}?api-version=2020-05-01 --only-show-errors --output none"
  "rest --method delete --url ${remediation_environment_id}?api-version=2024-10-01 --only-show-errors --output none"
  "rest --method delete --url ${remediation_owner_id}?api-version=2024-10-01 --only-show-errors --output none"
  "rest --method delete --url ${policy_assignment_id}?api-version=2025-03-01 --only-show-errors --output none"
  "rest --method delete --url ${remediation_role_id}?api-version=2022-04-01 --only-show-errors --output none"
  "rest --method delete --url ${policy_set_id}?api-version=2025-03-01 --only-show-errors --output none"
  "rest --method delete --url ${policy_inherit_id}?api-version=2025-03-01 --only-show-errors --output none"
  "rest --method delete --url ${policy_required_id}?api-version=2025-03-01 --only-show-errors --output none"
  "rest --method delete --url ${policy_locations_id}?api-version=2025-03-01 --only-show-errors --output none"
  "rest --method delete --url ${budget_id}?api-version=2024-08-01 --only-show-errors --output none"
  "rest --method delete --url ${reviewer_role_id}?api-version=2022-04-01 --only-show-errors --output none"
  "rest --method delete --url ${action_group_id}?api-version=2023-01-01 --only-show-errors --output none"
  "group delete --name ${resource_group_name} --subscription ${matching_subscription_id} --yes --no-wait --only-show-errors"
  "group wait --name ${resource_group_name} --subscription ${matching_subscription_id} --deleted --interval 10 --timeout 600 --only-show-errors"
  "rest --method delete --url ${subscription_budget_deployment_id}?api-version=2025-04-01 --only-show-errors --output none"
  "rest --method delete --url ${policy_governance_deployment_id}?api-version=2025-04-01 --only-show-errors --output none"
  "deployment sub delete --name aglab-governance --subscription ${matching_subscription_id} --only-show-errors"
)
[[ ${#mutation_log[@]} -eq ${#expected_mutations[@]} ]] || \
  fail "Expected ${#expected_mutations[@]} ordered cleanup operations, got ${#mutation_log[@]}."
for index in "${!expected_mutations[@]}"; do
  [[ ${mutation_log[index]} == "${expected_mutations[index]}" ]] || \
    fail "Cleanup order mismatch at operation $((index + 1)): ${mutation_log[index]}"
done

# Disabled/absent optionals skip exact IDs but mandatory resources still clean up.
reset_scenario
export MOCK_LOCKS_JSON='[]'
export MOCK_ROLE_ASSIGNMENTS_JSON='[]'
MOCK_ABSENT_RESOURCE_IDS_JSON="$(jq -cn \
  --arg lock "${lock_id}" --arg reviewer "${reviewer_role_id}" \
  --arg remediation_role "${remediation_role_id}" \
  --arg remediation_environment "${remediation_environment_id}" \
  --arg remediation_owner "${remediation_owner_id}" \
  '[$lock, $reviewer, $remediation_role, $remediation_environment, $remediation_owner]')"
export MOCK_ABSENT_RESOURCE_IDS_JSON
run_cleanup >/dev/null || fail 'Cleanup failed with all optional resources absent.'
if grep -Fq "rest --method delete --url ${lock_id}?" "${mock_log}" ||
   grep -Fq "rest --method delete --url ${reviewer_role_id}?" "${mock_log}" ||
   grep -Fq "rest --method delete --url ${remediation_role_id}?" "${mock_log}"; then
  fail 'Cleanup tried to delete an optional resource verified absent.'
fi

# A late-stage rerun can finish deterministic records after the RG is absent.
reset_scenario
export MOCK_GROUP_EXISTS_OUTPUT=false
MOCK_ABSENT_RESOURCE_IDS_JSON="$(jq -cn \
  --arg lock "${lock_id}" --arg reviewer "${reviewer_role_id}" \
  --arg action "${action_group_id}" --arg module "${subscription_budget_deployment_id}" \
  '[$lock, $reviewer, $action, $module]')"
export MOCK_ABSENT_RESOURCE_IDS_JSON
run_cleanup >/dev/null || fail 'Cleanup could not resume after verified resource-group absence.'
if grep -Eq '^(resource list|lock list|role assignment list|deployment group list|group show|group delete|group wait)' "${mock_log}"; then
  fail 'RG-absent resume queried or mutated the missing group after existence was verified false.'
fi
grep -Fq "rest --method delete --url ${policy_governance_deployment_id}?api-version=2025-04-01" "${mock_log}" || \
  fail 'RG-absent resume did not delete the remaining subscription module record.'
grep -Fq 'deployment sub delete --name aglab-governance' "${mock_log}" || \
  fail 'RG-absent resume did not delete the root deployment record last.'

printf 'PASS Bash lifecycle guards, strict drift inventories, partial reruns, and exact cleanup ordering.\n'
