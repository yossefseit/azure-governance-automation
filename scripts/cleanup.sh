#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

subscription_id=''
deployment_name='aglab-governance'
confirmation=''

usage() {
  cat <<'USAGE'
Usage: cleanup.sh --subscription-id ID --deployment-name NAME --confirmation DELETE:NAME

Deletes only exact lab resource types/names recorded in this deployment's cleanup
manifest. It rejects unexpected resource-group contents before any delete,
rechecks an empty group immediately before group deletion, removes deterministic
deployment records last, and never changes Azure context.

Options:
  --subscription-id ID   Required personally owned lab subscription ID
  --deployment-name NAME Exact successful deployment name
  --confirmation TEXT    Must exactly equal DELETE:<deployment-name>
  --help                 Show this message
USAGE
}

while (($# > 0)); do
  case "$1" in
    --subscription-id) subscription_id="${2:-}"; shift 2 ;;
    --deployment-name) deployment_name="${2:-}"; shift 2 ;;
    --confirmation) confirmation="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n ${subscription_id} ]] || fail '--subscription-id is required.'
validate_deployment_name "${deployment_name}"
assert_subscription_context "${subscription_id}"
[[ ${confirmation} == "DELETE:${deployment_name}" ]] || \
  fail "Cleanup stopped. Pass --confirmation DELETE:${deployment_name} after preserving sanitized evidence."
require_command jq

if ! manifest_json="$(az deployment sub show \
  --name "${deployment_name}" \
  --subscription "${subscription_id}" \
  --query properties.outputs.cleanupManifest.value \
  --output json \
  --only-show-errors)"; then
  fail 'Could not read the deployment cleanup manifest; nothing was deleted.'
fi

jq -e '
  .schemaVersion == "1.2" and
  .labMarker == "azure-governance-automation" and
  (.prefix | type == "string" and length >= 3 and length <= 12) and
  (.governanceResourceGroupName | type == "string" and length > 0) and
  (.deploymentNames | type == "object") and
  (.deploymentNames.subscriptionModules | type == "array") and
  (.deploymentNames.resourceGroupModules | type == "array") and
  (.resourceIds | type == "object") and
  (.resourceIds.policyDefinitions | type == "array") and
  (.resourceIds.remediations | type == "array")
' <<<"${manifest_json}" >/dev/null || fail 'Cleanup manifest failed schema or lab-marker validation; nothing was deleted.'

prefix="$(jq -r '.prefix' <<<"${manifest_json}")"
[[ ${prefix} =~ ^[a-z0-9]{3,12}$ ]] || fail 'Manifest prefix is not lowercase alphanumeric; nothing was deleted.'
governance_resource_group="$(jq -r '.governanceResourceGroupName' <<<"${manifest_json}")"
[[ ${governance_resource_group} == "rg-${prefix}-governance" ]] || \
  fail 'Manifest resource-group name does not match its prefix; nothing was deleted.'

subscription_base="/subscriptions/${subscription_id}"
resource_group_id="${subscription_base}/resourceGroups/${governance_resource_group}"
expected_lock_id="${resource_group_id}/providers/Microsoft.Authorization/locks/${prefix}-delete-protection"
expected_action_group_id="${resource_group_id}/providers/Microsoft.Insights/actionGroups/ag-${prefix}-cost"
expected_budget_id="${subscription_base}/providers/Microsoft.Consumption/budgets/${prefix}-monthly-guardrail"
expected_policy_assignment_id="${subscription_base}/providers/Microsoft.Authorization/policyAssignments/${prefix}-guardrails"
expected_policy_set_id="${subscription_base}/providers/Microsoft.Authorization/policySetDefinitions/${prefix}-baseline"

expected_subscription_deployment_names=(
  "${prefix}-subscription-budget"
  "${prefix}-policy-governance"
)
expected_resource_group_deployment_names=(
  "${prefix}-notification-group"
  "${prefix}-reviewer-access"
  "${prefix}-resource-lock"
)

assert_exact_name_set() {
  local json_path="$1"
  local label="$2"
  shift 2
  local -a expected=("$@")
  local -a actual=()
  local value
  local expected_value
  local found
  local -A seen=()

  jq -e "${json_path} | type == \"array\" and all(.[]; type == \"string\" and length > 0)" \
    <<<"${manifest_json}" >/dev/null || \
    fail "${label} contains an invalid name; nothing was deleted."
  mapfile -t actual < <(jq -er "${json_path}[]" <<<"${manifest_json}")
  [[ ${#actual[@]} -eq ${#expected[@]} ]] || \
    fail "${label} manifest set is incomplete or contains extra entries; nothing was deleted."
  for value in "${actual[@]}"; do
    [[ -n ${value} && ${value} != *$'\n'* && ${value} != *$'\r'* ]] || \
      fail "${label} contains an invalid name; nothing was deleted."
    [[ -z ${seen[${value,,}]+x} ]] || \
      fail "${label} contains a duplicate name; nothing was deleted."
    seen[${value,,}]=1
    found=false
    for expected_value in "${expected[@]}"; do
      [[ ${value,,} == "${expected_value,,}" ]] && found=true
    done
    [[ ${found} == true ]] || \
      fail "${label} contains an unexpected name; nothing was deleted."
  done
}

assert_exact_name_set \
  '.deploymentNames.subscriptionModules' \
  'Subscription module deployment names' \
  "${expected_subscription_deployment_names[@]}"
assert_exact_name_set \
  '.deploymentNames.resourceGroupModules' \
  'Resource-group module deployment names' \
  "${expected_resource_group_deployment_names[@]}"

mapfile -t subscription_deployment_names < <(
  jq -r '.deploymentNames.subscriptionModules[]' <<<"${manifest_json}"
)
mapfile -t resource_group_deployment_names < <(
  jq -r '.deploymentNames.resourceGroupModules[]' <<<"${manifest_json}"
)
subscription_deployment_ids=()
for module_name in "${subscription_deployment_names[@]}"; do
  subscription_deployment_ids+=(
    "${subscription_base}/providers/Microsoft.Resources/deployments/${module_name}"
  )
done

assert_exact_id() {
  local resource_id="$1"
  local expected_id="$2"
  local label="$3"
  if [[ -z ${resource_id} ]]; then
    fail "${label} is missing from the cleanup manifest; nothing was deleted."
  fi
  [[ ${resource_id} != *$'\n'* && ${resource_id} != *$'\r'* ]] || \
    fail "${label} contains an invalid line break; nothing was deleted."
  [[ ${resource_id,,} == "${expected_id,,}" ]] || \
    fail "${label} does not match the exact expected lab resource ID; nothing was deleted."
}

lock_id="$(jq -r '.resourceIds.lock // ""' <<<"${manifest_json}")"
action_group_id="$(jq -r '.resourceIds.actionGroup // ""' <<<"${manifest_json}")"
budget_id="$(jq -r '.resourceIds.budget // ""' <<<"${manifest_json}")"
reviewer_role_id="$(jq -r '.resourceIds.reviewerRoleAssignment // ""' <<<"${manifest_json}")"
policy_assignment_id="$(jq -r '.resourceIds.policyAssignment // ""' <<<"${manifest_json}")"
remediation_role_id="$(jq -r '.resourceIds.remediationRoleAssignment // ""' <<<"${manifest_json}")"
policy_set_id="$(jq -r '.resourceIds.policySetDefinition // ""' <<<"${manifest_json}")"
mapfile -t policy_definition_ids < <(jq -r '.resourceIds.policyDefinitions[]' <<<"${manifest_json}")
mapfile -t remediation_ids < <(jq -r '.resourceIds.remediations[]' <<<"${manifest_json}")

assert_exact_id "${lock_id}" "${expected_lock_id}" 'Lock ID'
assert_exact_id "${action_group_id}" "${expected_action_group_id}" 'Action group ID'
assert_exact_id "${budget_id}" "${expected_budget_id}" 'Budget ID'
assert_exact_id "${policy_assignment_id}" "${expected_policy_assignment_id}" 'Policy assignment ID'
assert_exact_id "${policy_set_id}" "${expected_policy_set_id}" 'Policy set definition ID'

expected_policy_definition_ids=(
  "${subscription_base}/providers/Microsoft.Authorization/policyDefinitions/${prefix}-inherit-rg-tag"
  "${subscription_base}/providers/Microsoft.Authorization/policyDefinitions/${prefix}-require-rg-tag"
  "${subscription_base}/providers/Microsoft.Authorization/policyDefinitions/${prefix}-allowed-locations"
)
[[ ${#policy_definition_ids[@]} -eq ${#expected_policy_definition_ids[@]} ]] || \
  fail 'Policy definition manifest count is unexpected; nothing was deleted.'
for expected_id in "${expected_policy_definition_ids[@]}"; do
  found=false
  for resource_id in "${policy_definition_ids[@]}"; do
    [[ ${resource_id,,} == "${expected_id,,}" ]] && found=true
  done
  [[ ${found} == true ]] || fail 'Policy definition manifest set is unexpected; nothing was deleted.'
done

expected_remediation_ids=(
  "${subscription_base}/providers/Microsoft.PolicyInsights/remediations/${prefix}-remediate-environment"
  "${subscription_base}/providers/Microsoft.PolicyInsights/remediations/${prefix}-remediate-owner"
)
[[ ${#remediation_ids[@]} -eq 2 ]] || \
  fail 'Remediation manifest count is unexpected; nothing was deleted.'
for resource_id in "${remediation_ids[@]}"; do
  allowed=false
  for expected_id in "${expected_remediation_ids[@]}"; do
    [[ ${resource_id,,} == "${expected_id,,}" ]] && allowed=true
  done
  [[ ${allowed} == true ]] || fail 'Remediation ID is not an expected lab remediation; nothing was deleted.'
done
for expected_id in "${expected_remediation_ids[@]}"; do
  found=false
  for resource_id in "${remediation_ids[@]}"; do
    [[ ${resource_id,,} == "${expected_id,,}" ]] && found=true
  done
  [[ ${found} == true ]] || fail 'Remediation manifest set is incomplete or duplicated; nothing was deleted.'
done

role_guid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
[[ ${remediation_role_id} =~ ^${subscription_base}/providers/Microsoft.Authorization/roleAssignments/${role_guid_pattern}$ ]] || \
  fail 'Remediation role assignment type or scope is unexpected; nothing was deleted.'
[[ ${reviewer_role_id} =~ ^${resource_group_id}/providers/Microsoft.Authorization/roleAssignments/${role_guid_pattern}$ ]] || \
  fail 'Reviewer role assignment type or scope is unexpected; nothing was deleted.'

run_inventory_command() {
  local label="$1"
  shift
  local output
  local status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ ${status} -eq 0 ]] || \
    fail "Could not inventory ${label}; cleanup stopped before further mutation."
  printf '%s' "${output}"
}

assert_allowed_string_inventory() {
  local inventory_json="$1"
  local label="$2"
  local require_empty="$3"
  shift 3
  local -a allowed=("$@")
  local -a actual=()
  local value
  local allowed_value
  local is_allowed
  local -A seen=()

  jq -e '
    type == "array" and
    all(.[];
      type == "string" and
      length > 0 and
      (contains("\n") | not) and
      (contains("\r") | not) and
      (contains("\t") | not)
    )
  ' <<<"${inventory_json}" >/dev/null || \
    fail "${label} inventory was not a valid string array; cleanup stopped before further mutation."
  mapfile -t actual < <(jq -r '.[]' <<<"${inventory_json}")
  for value in "${actual[@]}"; do
    [[ -z ${seen[${value,,}]+x} ]] || \
      fail "${label} inventory contains a duplicate item; cleanup stopped before further mutation."
    seen[${value,,}]=1
    if [[ ${require_empty} == true ]]; then
      fail "${label} inventory is not empty before resource-group deletion; cleanup stopped."
    fi
    is_allowed=false
    for allowed_value in "${allowed[@]}"; do
      [[ ${value,,} == "${allowed_value,,}" ]] && is_allowed=true
    done
    [[ ${is_allowed} == true ]] || \
      fail "${label} inventory contains an unexpected item; cleanup stopped before further mutation."
  done
}

assert_allowed_role_inventory() {
  local inventory_json="$1"
  local label="$2"
  local expected_scope="$3"
  local require_empty="$4"
  local allowed_role_id="$5"
  local expected_role_definition_id="$6"
  local -a rows=()
  local row
  local role_id
  local role_scope
  local role_definition_id
  local principal_id
  local -A seen=()
  local principal_guid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  jq -e '
    type == "array" and
    all(.[];
      type == "object" and
      (.id | type == "string" and length > 0) and
      (.scope | type == "string" and length > 0) and
      (.roleDefinitionId | type == "string" and length > 0) and
      (.principalId | type == "string" and length > 0) and
      ([.id, .scope, .roleDefinitionId, .principalId] |
        all(.[];
          (contains("\n") | not) and
          (contains("\r") | not) and
          (contains("\t") | not)
        ))
    )
  ' <<<"${inventory_json}" >/dev/null || \
    fail "${label} inventory was not a valid assignment array; cleanup stopped before further mutation."
  mapfile -t rows < <(jq -r '.[] | [.id, .scope, .roleDefinitionId, .principalId] | @tsv' <<<"${inventory_json}")
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r role_id role_scope role_definition_id principal_id <<<"${row}"
    [[ -z ${seen[${role_id,,}]+x} ]] || \
      fail "${label} inventory contains a duplicate item; cleanup stopped before further mutation."
    seen[${role_id,,}]=1
    if [[ ${role_scope,,} == "${expected_scope,,}" ]]; then
      if [[ ${require_empty} == true ]]; then
        fail "${label} inventory is not empty; cleanup stopped."
      fi
      [[ ${role_id,,} == "${allowed_role_id,,}" ]] || \
        fail "${label} inventory contains an unexpected exact-scope assignment; cleanup stopped before further mutation."
      [[ ${role_definition_id,,} == "${expected_role_definition_id,,}" && ${principal_id} =~ ${principal_guid_pattern} ]] || \
        fail "${label} inventory properties are unexpected; cleanup stopped before further mutation."
    elif [[ ${role_scope,,} == "${expected_scope,,}/"* ]]; then
      fail "${label} inventory contains an unexpected descendant-scope assignment; cleanup stopped before further mutation."
    fi
  done
}

validate_resource_group_markers() {
  local resource_group_json
  local actual_marker
  local actual_managed_by
  local actual_resource_group_id
  if ! resource_group_json="$(az group show \
    --name "${governance_resource_group}" \
    --subscription "${subscription_id}" \
    --output json \
    --only-show-errors)"; then
    fail 'Could not read and verify the governance resource group; cleanup stopped.'
  fi
  jq -e 'type == "object" and (.tags | type == "object") and (.id | type == "string")' \
    <<<"${resource_group_json}" >/dev/null || \
    fail 'Resource-group marker inventory was malformed; cleanup stopped.'
  actual_marker="$(jq -r '.tags.portfolioLab // ""' <<<"${resource_group_json}")"
  actual_managed_by="$(jq -r '.tags.managedBy // ""' <<<"${resource_group_json}")"
  actual_resource_group_id="$(jq -r '.id // ""' <<<"${resource_group_json}")"
  [[ ${actual_marker} == 'azure-governance-automation' && ${actual_managed_by} == 'bicep' ]] || \
    fail 'Resource-group safety markers do not match; cleanup stopped.'
  [[ ${actual_resource_group_id,,} == "${resource_group_id,,}" ]] || \
    fail 'Resource-group ID does not match the exact expected lab scope; cleanup stopped.'
}

validate_resource_group_inventory() {
  local require_empty="$1"
  local direct_resources_json
  local locks_json
  local subscription_roles_json
  local deployments_json

  direct_resources_json="$(run_inventory_command 'direct resource-group resources' \
    az resource list \
      --subscription "${subscription_id}" \
      --resource-group "${governance_resource_group}" \
      --query '[].id' \
      --output json \
      --only-show-errors)"
  locks_json="$(run_inventory_command 'resource-group locks' \
    az lock list \
      --subscription "${subscription_id}" \
      --resource-group "${governance_resource_group}" \
      --query '[].id' \
      --output json \
      --only-show-errors)"
  subscription_roles_json="$(run_inventory_command 'subscription role assignments' \
    az role assignment list \
      --subscription "${subscription_id}" \
      --all \
      --fill-principal-name false \
      --fill-role-definition-name false \
      --query '[].{id:id,scope:scope,roleDefinitionId:roleDefinitionId,principalId:principalId}' \
      --output json \
      --only-show-errors)"
  deployments_json="$(run_inventory_command 'resource-group deployment records' \
    az deployment group list \
      --subscription "${subscription_id}" \
      --resource-group "${governance_resource_group}" \
      --query '[].name' \
      --output json \
      --only-show-errors)"

  assert_allowed_string_inventory \
    "${direct_resources_json}" \
    'Direct resource-group resource' \
    "${require_empty}" \
    "${action_group_id}"
  assert_allowed_string_inventory \
    "${locks_json}" \
    'Resource-group lock' \
    "${require_empty}" \
    "${lock_id}"
  assert_allowed_role_inventory \
    "${subscription_roles_json}" \
    'Resource-group role-assignment' \
    "${resource_group_id}" \
    "${require_empty}" \
    "${reviewer_role_id}" \
    "${subscription_base}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
  assert_allowed_string_inventory \
    "${deployments_json}" \
    'Resource-group deployment record' \
    false \
    "${resource_group_deployment_names[@]}"
}

get_resource_group_presence() {
  local output
  local status
  set +e
  output="$(az group exists \
    --name "${governance_resource_group}" \
    --subscription "${subscription_id}" \
    --only-show-errors 2>&1)"
  status=$?
  set -e
  [[ ${status} -eq 0 ]] || \
    fail 'Could not determine whether the governance resource group exists; nothing was deleted.'
  case "${output}" in
    true|false) printf '%s' "${output}" ;;
    *) fail 'Resource-group existence inventory returned an invalid value; nothing was deleted.' ;;
  esac
}

# Ownership and complete resource-group contents are checked before any delete,
# including the lock. A verified absent group permits a late-stage partial rerun
# to finish only the manifest-bound subscription resources/deployment records.
resource_group_present="$(get_resource_group_presence)"
if [[ ${resource_group_present} == true ]]; then
  validate_resource_group_markers
  validate_resource_group_inventory false
fi

resource_exists() {
  local resource_id="$1"
  local api_version="$2"
  local query_output
  local query_status
  set +e
  query_output="$(az rest --method get --url "${resource_id}?api-version=${api_version}" --only-show-errors --output none 2>&1)"
  query_status=$?
  set -e
  if [[ ${query_status} -eq 0 ]]; then
    return 0
  fi
  if [[ ${query_output} =~ (^|[^[:alnum:]_])[[:alpha:]][[:alnum:]]*NotFound([^[:alnum:]_]|$) ]] || \
    [[ ${query_output} =~ (HTTP|status|Status)([[:space:]]+(code|Code))?[[:space:]:=]+404([^[:digit:]]|$) ]]; then
    return 1
  fi
  fail "Could not verify resource state before deletion: ${query_output}"
}

validate_role_assignment() {
  local resource_id="$1"
  local expected_scope="$2"
  local expected_role_guid="$3"
  local expected_principal_type="$4"
  local expected_description="$5"
  local label="$6"
  local role_json
  [[ -z ${resource_id} ]] && return 0
  if ! resource_exists "${resource_id}" '2022-04-01'; then
    return 0
  fi
  if ! role_json="$(az rest --method get --url "${resource_id}?api-version=2022-04-01" --only-show-errors --output json)"; then
    fail "Could not inspect ${label}; nothing was deleted."
  fi
  jq -e \
    --arg scope "${expected_scope,,}" \
    --arg role_suffix "/providers/microsoft.authorization/roledefinitions/${expected_role_guid,,}" \
    --arg principal_type "${expected_principal_type}" \
    --arg description "${expected_description}" '
      ((.properties.scope // "") | ascii_downcase) == $scope and
      ((.properties.roleDefinitionId // "") | ascii_downcase | endswith($role_suffix)) and
      .properties.principalType == $principal_type and
      .properties.description == $description
    ' <<<"${role_json}" >/dev/null || fail "${label} properties do not match the lab assignment; nothing was deleted."
}

validate_role_assignment \
  "${remediation_role_id}" \
  "${subscription_base}" \
  '4a9ae827-6dc8-4573-8ac7-8239d42aa03f' \
  'ServicePrincipal' \
  'Allows only the policy assignment managed identity to remediate resource tags at assignment scope.' \
  'remediation role assignment'
validate_role_assignment \
  "${reviewer_role_id}" \
  "${resource_group_id}" \
  'acdd72a7-3385-48ef-bd42-f606fba81ae7' \
  'Group' \
  'Read-only access to the governance lab resource group.' \
  'reviewer role assignment'

delete_resource_id() {
  local resource_id="$1"
  local api_version="$2"
  local label="$3"
  [[ -z ${resource_id} ]] && return 0
  if ! resource_exists "${resource_id}" "${api_version}"; then
    printf 'Already absent; skipping %s: %s\n' "${label}" "${resource_id}"
    return 0
  fi
  printf 'Deleting %s: %s\n' "${label}" "${resource_id}"
  az rest \
    --method delete \
    --url "${resource_id}?api-version=${api_version}" \
    --only-show-errors \
    --output none
}

print_context_confirmation "${subscription_id}" "cleanup deployment ${deployment_name}"

# Dependency order is deliberate: lock first; remediation before assignment;
# assignment before initiative; initiative before definitions; budget before its
# action group; direct RG resources and assignments before the marked group;
# deterministic nested deployment records before the root deployment record.
delete_resource_id "${lock_id}" '2020-05-01' 'management lock'
for resource_id in "${remediation_ids[@]}"; do delete_resource_id "${resource_id}" '2024-10-01' 'policy remediation'; done
delete_resource_id "${policy_assignment_id}" '2025-03-01' 'policy assignment'
delete_resource_id "${remediation_role_id}" '2022-04-01' 'policy identity role assignment'
delete_resource_id "${policy_set_id}" '2025-03-01' 'policy initiative'
for resource_id in "${policy_definition_ids[@]}"; do delete_resource_id "${resource_id}" '2025-03-01' 'policy definition'; done
delete_resource_id "${budget_id}" '2024-08-01' 'subscription budget'
delete_resource_id "${reviewer_role_id}" '2022-04-01' 'optional reviewer role assignment'
delete_resource_id "${action_group_id}" '2023-01-01' 'action group'

if [[ ${resource_group_present} == true ]]; then
  # Close the inventory-to-delete gap as far as practical: no mutation occurs
  # between this final empty-content/ownership check and the group delete request.
  validate_resource_group_inventory true
  validate_resource_group_markers

  az group delete \
    --name "${governance_resource_group}" \
    --subscription "${subscription_id}" \
    --yes \
    --no-wait \
    --only-show-errors
  az group wait \
    --name "${governance_resource_group}" \
    --subscription "${subscription_id}" \
    --deleted \
    --interval 10 \
    --timeout 600 \
    --only-show-errors
fi

for deployment_id in "${subscription_deployment_ids[@]}"; do
  delete_resource_id "${deployment_id}" '2025-04-01' 'subscription module deployment record'
done

az deployment sub delete \
  --name "${deployment_name}" \
  --subscription "${subscription_id}" \
  --only-show-errors

printf 'Cleanup completed; the governance resource group is absent and deterministic deployment records were processed. Preserve the command result only as sanitized evidence.\n'
