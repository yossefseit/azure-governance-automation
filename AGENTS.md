# Repository working agreement

## Purpose

This repository is a zero-workload Azure governance lab. It demonstrates a
small, subscription-scoped baseline; it is not an Azure landing zone and must
not be represented as a deployed production environment.

## Truth rules

- Distinguish authored, linted, compiled, CI validated, Azure validated,
  what-if reviewed, deployed, runtime tested, and teardown tested.
- Do not add terminal output, screenshots, cost results, or compliance results
  unless they came from a real, sanitized run.
- Never commit tenant IDs, subscription IDs, principal IDs, email addresses,
  credentials, deployment output, or policy evidence containing resource IDs.
- Budgets are alerts, not hard spending caps. Policy compliance can be delayed.
- A Bicep build proves syntax/type compilation only; it is not ARM validation.

## Safety rules

- Never call `az account set` or change an Azure context in a script.
- Every authenticated script must require an explicit subscription ID and stop
  when it does not exactly match `az account show`.
- Deploy and cleanup require explicit confirmation strings. Cleanup deletes
  only IDs returned by this template's deployment outputs, removes the lock
  first, and checks the resource-group marker before deleting the group.
- Do not deploy, run what-if, or clean up against an employer-owned or
  ownership-uncertain tenant. Do not create paid resources.
- Keep optional human access group-based and at the narrowest demonstrated
  scope. Do not replace stable built-in role IDs with role-name lookups.

## Commands

From the repository root:

```bash
BICEP_BIN=/path/to/bicep bash tests/run.sh
```

Authenticated checks are documented in `docs/deployment.md`. They require a
personally owned lab subscription and deliberate confirmation.

## Conventions

- Bicep lives in `infra/`; keep subscription and resource-group scope boundaries
  visible through modules.
- Bash and PowerShell operational scripts must retain behavioral parity.
- Keep official sources close to design decisions in `docs/`.
- Update the README status matrix after, not before, evidence is produced.
- Do not commit generated ARM JSON or local parameter files.

## Definition of done

The baseline must compile with the pinned Bicep version, pass offline tests and
static checks, contain no secrets or real identifiers, document cost and access
side effects, and leave all unperformed Azure/runtime/teardown evidence pending.
