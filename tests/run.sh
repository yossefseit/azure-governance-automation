#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${TEST_DIR}/.." && pwd)"
TEST_TEMP_DIR="$(mktemp -d)"
trap 'rm -r -- "${TEST_TEMP_DIR}"' EXIT

cd "${REPOSITORY_ROOT}"

python3 tests/static.py

for script in scripts/*.sh scripts/lib/*.sh tests/*.sh tests/fixtures/az; do
  bash -n "${script}"
done
printf 'PASS Bash syntax checks.\n'

# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
run_bicep_checks "${DEFAULT_TEMPLATE_FILE}" "${DEFAULT_PARAMETERS_FILE}"
printf 'PASS Bicep lint, template build, and parameter build.\n'

if [[ -n ${BICEP_BIN:-} ]]; then
  "${BICEP_BIN}" build "${DEFAULT_TEMPLATE_FILE}" --outfile "${TEST_TEMP_DIR}/main.json"
elif command -v bicep >/dev/null 2>&1; then
  bicep build "${DEFAULT_TEMPLATE_FILE}" --outfile "${TEST_TEMP_DIR}/main.json"
else
  az bicep build --file "${DEFAULT_TEMPLATE_FILE}" --outfile "${TEST_TEMP_DIR}/main.json"
fi
python3 tests/compiled-template.py "${TEST_TEMP_DIR}/main.json"

bash tests/shell-guards.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh scripts/lib/*.sh tests/*.sh tests/fixtures/az
  printf 'PASS ShellCheck.\n'
else
  printf 'SKIP ShellCheck is not installed; CI requires it.\n'
fi

if command -v pwsh >/dev/null 2>&1; then
  # PowerShell variables inside this literal must not expand in Bash.
  # shellcheck disable=SC2016
  pwsh -NoLogo -NoProfile -Command '
    $errors = @()
    Get-ChildItem scripts,tests -Filter *.ps1 -Recurse | ForEach-Object {
      $fileErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$fileErrors)
      $errors += $fileErrors
    }
    if ($errors.Count -gt 0) { $errors | Format-List; exit 1 }
  '
  pwsh -NoLogo -NoProfile -File tests/powershell-guards.ps1
  printf 'PASS PowerShell parser and guard checks.\n'
else
  printf 'SKIP PowerShell checks require pwsh; CI runs them.\n'
fi

printf 'All available local checks passed.\n'
