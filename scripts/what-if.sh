#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

subscription_id=''
location='westeurope'
deployment_name='aglab-whatif'
template_file="${DEFAULT_TEMPLATE_FILE}"
parameters_file="${DEFAULT_PARAMETERS_FILE}"

usage() {
  cat <<'USAGE'
Usage: what-if.sh --subscription-id ID [options]

Runs local compilation and an authenticated subscription what-if. What-if does
not create resources, but it requires Azure permissions and must still target a
personally owned lab subscription.

Options:
  --subscription-id ID   Required personally owned lab subscription ID
  --location LOCATION    Deployment-record location (default: westeurope)
  --deployment-name NAME What-if deployment name (default: aglab-whatif)
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
print_context_confirmation "${subscription_id}" 'subscription what-if (no deployment)'

az deployment sub what-if \
  --name "${deployment_name}" \
  --location "${location}" \
  --subscription "${subscription_id}" \
  --template-file "${template_file}" \
  --parameters "${parameters_file}" \
  --result-format FullResourcePayloads \
  --only-show-errors
