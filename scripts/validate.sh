#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

subscription_id=''
location='westeurope'
deployment_name='aglab-validate'
template_file="${DEFAULT_TEMPLATE_FILE}"
parameters_file="${DEFAULT_PARAMETERS_FILE}"

usage() {
  cat <<'USAGE'
Usage: validate.sh --subscription-id ID [options]

Runs local Bicep checks, verifies the current Azure context exactly, and calls
subscription deployment validation. It does not deploy resources or change the
Azure CLI subscription.

Options:
  --subscription-id ID   Required personally owned lab subscription ID
  --location LOCATION    Deployment-record location (default: westeurope)
  --deployment-name NAME Validation deployment name (default: aglab-validate)
  --parameters FILE      Bicep parameter file
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
print_context_confirmation "${subscription_id}" 'authenticated ARM validation (no deployment)'

az deployment sub validate \
  --name "${deployment_name}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${template_file}" \
  --parameters "${parameters_file}" \
  --only-show-errors \
  --output json
