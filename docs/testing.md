# Testing

## Local runner

```bash
BICEP_BIN=/path/to/bicep bash tests/run.sh
```

The runner is dependency-light and writes generated templates only to a temporary
directory. It performs:

- Bicep lint and main-template build;
- Bicep parameter-file build;
- compiled ARM checks for the prefix assertion, required stable budget date, and
  lazy conditional identity reference, manifest schema, and exact nested
  deployment names;
- Python standard-library repository invariant tests;
- `bash -n` on lifecycle and test scripts;
- mock Azure CLI tests for subscription mismatch, deploy/cleanup confirmation,
  incorrect resource-group ownership, command/malformed/duplicate/extra
  inventories, descendant-scope RBAC, incidental-404 errors, final inventory
  drift, optional-resource absence, group-absent resume, and the full lock-first
  delete, group-wait, and deployment-record order;
- ShellCheck when it is available;
- PowerShell parser/guard tests when `pwsh` is available.

Generated ARM JSON, test IDs, and mock logs are not committed.

## CI workflow

`.github/workflows/ci.yml` repeats the local checks and adds:

- Bicep 0.46.1 installation through Azure CLI;
- ShellCheck;
- PowerShell parser and PSScriptAnalyzer 1.25.0;
- Markdownlint and cspell;
- Markdown link validation;
- Gitleaks secret scanning.

Checkout v7.0.1 is pinned to its reviewed immutable SHA, disables persisted
credentials, and fetches full history for the secret scan. Repository scanners
exclude `.git` plus declared generated directories before UTF-8 reads; a static
regression check protects that rule. Markdownlint 0.23.2, CSpell 10.0.1,
PSScriptAnalyzer 1.25.0, and Gitleaks Action v3 are version-pinned; Dependabot
checks GitHub Actions monthly.

Actions are pinned to immutable commit SHAs and the workflow has only
`contents: read`. It never requests `id-token: write` and never authenticates to
Azure. A green workflow therefore means repository/compile validation, not Azure
validation.

## Manual review

After automation passes, inspect the complete tree and diff twice:

1. **Engineer pass:** API versions, scopes, dependencies, identity permissions,
   cleanup order, parameter defaults, idempotency, and unsupported claims.
2. **Recruiter pass:** purpose understood in two minutes, architecture visible,
   status unambiguous, commands reproducible, and limitations near the evidence.

Any update to template outputs must update both cleanup implementations and guard
tests in the same change.
