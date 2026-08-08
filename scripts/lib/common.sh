#!/usr/bin/env bash

COMMON_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${COMMON_SCRIPT_DIR}/../.." && pwd)"
# These defaults are intentionally consumed by scripts after sourcing this file.
# shellcheck disable=SC2034
DEFAULT_TEMPLATE_FILE="${REPOSITORY_ROOT}/infra/main.bicep"
# shellcheck disable=SC2034
DEFAULT_PARAMETERS_FILE="${REPOSITORY_ROOT}/infra/environments/lab.example.bicepparam"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

validate_subscription_id() {
  local subscription_id="$1"
  [[ ${subscription_id} =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || \
    fail 'Subscription ID must use GUID format.'
}

validate_deployment_name() {
  local deployment_name="$1"
  local deployment_name_pattern='^[a-zA-Z0-9._() -]{1,64}$'
  [[ ${deployment_name} =~ ${deployment_name_pattern} ]] || \
    fail 'Deployment name contains unsupported characters or exceeds 64 characters.'
}

assert_file() {
  [[ -f "$1" ]] || fail "File not found: $1"
}

assert_subscription_context() {
  local expected_subscription_id="$1"
  local current_subscription_id

  require_command az
  validate_subscription_id "${expected_subscription_id}"

  if ! current_subscription_id="$(az account show --query id --output tsv --only-show-errors)"; then
    fail 'Unable to read the current Azure CLI account. Sign in to a personally owned lab context and retry.'
  fi
  current_subscription_id="${current_subscription_id//$'\r'/}"
  [[ -n ${current_subscription_id} ]] || fail 'Azure CLI returned an empty subscription ID.'

  if [[ ${current_subscription_id,,} != "${expected_subscription_id,,}" ]]; then
    fail "Azure context mismatch. Requested ${expected_subscription_id}; current context is ${current_subscription_id}. Context was not changed."
  fi
}

run_bicep_checks() {
  local template_file="$1"
  local parameters_file="$2"

  assert_file "${template_file}"
  assert_file "${parameters_file}"

  (
    local validation_temp_dir
    validation_temp_dir="$(mktemp -d)"
    trap 'rm -r -- "${validation_temp_dir}"' EXIT

    if [[ -n ${BICEP_BIN:-} ]]; then
      [[ -x ${BICEP_BIN} ]] || fail "BICEP_BIN is not executable: ${BICEP_BIN}"
      "${BICEP_BIN}" lint "${template_file}"
      "${BICEP_BIN}" build "${template_file}" --outfile "${validation_temp_dir}/main.json"
      "${BICEP_BIN}" build-params "${parameters_file}" --outfile "${validation_temp_dir}/parameters.json"
    elif command -v bicep >/dev/null 2>&1; then
      bicep lint "${template_file}"
      bicep build "${template_file}" --outfile "${validation_temp_dir}/main.json"
      bicep build-params "${parameters_file}" --outfile "${validation_temp_dir}/parameters.json"
    else
      require_command az
      az bicep version
      az bicep lint --file "${template_file}"
      az bicep build --file "${template_file}" --outfile "${validation_temp_dir}/main.json"
      az bicep build-params --file "${parameters_file}" --outfile "${validation_temp_dir}/parameters.json"
    fi
  )
}

print_context_confirmation() {
  local subscription_id="$1"
  local action="$2"
  printf 'Azure context verified: %s\n' "${subscription_id}"
  printf 'Requested operation: %s\n' "${action}"
  printf 'No Azure subscription or tenant was changed by this script.\n'
}
