#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

subscription_id=''
location='westeurope'
deployment_name='aglab-governance'
template_file="${DEFAULT_TEMPLATE_FILE}"
parameters_file="${DEFAULT_PARAMETERS_FILE}"

usage() {
  cat <<'USAGE'
Usage: deploy.sh --subscription-id ID [options]

Creates governance control-plane resources in the exact current Azure
subscription. This script never changes Azure context. Deployment must use a
personally owned lab and requires a prior validate and reviewed what-if.

Options:
  --subscription-id ID   Required personally owned lab subscription ID
  --location LOCATION    Deployment-record location (default: westeurope)
  --deployment-name NAME Deployment name (default: aglab-governance)
  --parameters FILE      Uncommitted Bicep parameter file
  --template FILE        Main Bicep file
  --help                 Show this message
USAGE
}

while (($# > 0)); do
  case "$1" in
    --subscription-id) subscription_id="${2:-}"; shift 2 ;;
    --location) location="${2:-}"; shift 2 ;;
    --deployment-name) deployment_name="${2:-}"; shift 2 ;;
    --parameters) parameters_file="${2:-}"; shift 2 ;;
    --template) template_file="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n ${subscription_id} ]] || fail '--subscription-id is required.'
[[ -n ${location} ]] || fail '--location must not be empty.'
validate_deployment_name "${deployment_name}"
assert_subscription_context "${subscription_id}"
run_bicep_checks "${template_file}" "${parameters_file}"

print_context_confirmation "${subscription_id}" 'mandatory pre-deployment ARM validation'
az deployment sub validate \
  --name "${deployment_name}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${template_file}" \
  --parameters "${parameters_file}" \
  --only-show-errors \
  --output json

print_context_confirmation "${subscription_id}" 'mandatory pre-deployment full what-if'
az deployment sub what-if \
  --name "${deployment_name}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${template_file}" \
  --parameters "${parameters_file}" \
  --result-format FullResourcePayloads \
  --only-show-errors

printf 'Type DEPLOY:%s to create the reviewed resources: ' "${deployment_name}" >&2
IFS= read -r final_confirmation || fail 'Deployment stopped because final interactive confirmation was not provided.'
[[ ${final_confirmation} == "DEPLOY:${deployment_name}" ]] || \
  fail "Deployment stopped. Final confirmation did not equal DEPLOY:${deployment_name}."

print_context_confirmation "${subscription_id}" "deployment ${deployment_name}"

az deployment sub create \
  --name "${deployment_name}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${template_file}" \
  --parameters "${parameters_file}" \
  --only-show-errors \
  --output json
