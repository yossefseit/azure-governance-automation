# Validation plan

## Evidence ladder

Each level proves something different:

1. **Authored** — code and runbooks exist.
2. **Linted/compiled** — Bicep and static checks accept the files locally.
3. **CI validated** — the exact public commit passes the GitHub workflow.
4. **Authenticated ARM validated** — Azure Resource Manager accepts the template
   and parameters for a specific subscription without deployment.
5. **What-if reviewed** — a human reviews the predicted changes and limits.
6. **Deployed** — Azure reports a successful subscription deployment.
7. **Runtime tested** — policy, identity, alert routing, RBAC, and lock behavior
   are observed against controlled resources.
8. **Teardown tested** — guarded cleanup completes and deletion is observed.
9. **Cost verified** — delayed billing data is reviewed after the test window.

Do not collapse one level into another in the README matrix.

## Offline acceptance

| Test | Expected result | Current status |
| --- | --- | --- |
| Bicep lint/build | No errors; expected `languageVersion: 2.1-experimental` assertion warning disclosed | Passed locally with 0.46.1 |
| Example parameter compile | Generates ARM parameter JSON in `/tmp` only | Passed locally |
| Repository invariants | Required files, safety text, stable role IDs, scan exclusions, no obvious real identifiers | Passed locally: 11 tests |
| Bash syntax/static analysis | `bash -n` and ShellCheck clean | Passed locally with ShellCheck 0.11.0 |
| PowerShell parse/static analysis | Parser and PSScriptAnalyzer clean | Passed locally with PowerShell 7.5.0 and PSScriptAnalyzer 1.25.0 |
| Guard behavior | Wrong context/confirmation/ownership, malformed/extra inventory, descendant RBAC, and non-404 errors stop safely; partial and successful mocks follow exact order | Passed locally for Bash and PowerShell with the mock Azure CLI |
| GitHub Actions | Repeat offline checks, documentation/link validation, and secret scanning on the public commit | Passed on public `main` |

The CI badge links to the current public workflow history. A green workflow is
repository and compile evidence only; it is not authenticated Azure validation.

## Azure validation cases

Run only in a personally owned, cost-approved subscription.

| Case | Positive observation | Negative observation / rollback |
| --- | --- | --- |
| ARM validation | Server accepts all types, API versions, parameters, and scope | No resources created; failure is not deployment evidence |
| What-if | Only named governance resources and deterministic assignments appear | Any unexpected delete, broad scope, or remediation stops the deployment |
| Deployment | Deployment succeeds; output manifest matches named resources | Partial failure inventory is captured and reconciled before retry |
| Required RG tags | A controlled untagged RG is non-compliant under Audit | Switch to Disabled if legitimate RG types are incorrectly evaluated |
| Location | A controlled resource in an unlisted region is audited | Do not switch to Deny until locationless/global/service exceptions are reviewed |
| Tag inheritance | After separately enabling `Modify`, a taggable controlled resource missing `environment` inherits parent value on create/update | Disabled baseline makes no tag write; an explicit resource value must not be overwritten |
| Remediation | With separate approval, at most the bounded set is remediated | Disable/delete tasks if any unexpected resource is selected |
| Reviewer access | Approved group can read governance RG and cannot modify it | Confirm an unrelated principal has no new access |
| Delete lock | Deleting the controlled governance RG fails while lock exists | Updates must remain possible under `CanNotDelete` |
| Budget routing | Action group has the approved receiver; a genuine budget event eventually arrives | Do not fabricate/force spend to trigger evidence; empty receivers cannot deliver |
| Cleanup | Script inventories allowlisted RG contents, deletes only manifest IDs, removes lock first, rechecks emptiness/markers, observes RG absence, then deletes exact deployment records | Wrong ID/marker/extra resource/query failure stops before group deletion |

Policy state can take time to propagate. Record timestamps and distinguish
`NotStarted`, `Compliant`, `NonCompliant`, and evaluation delay. Do not invent an
SLA or treat one resource type as proof for every provider.

## Evidence capture

Use [the sanitized template](../evidence/evidence-template.md). Capture command
version, commit SHA, UTC time, intended scope label, result, and redactions.
Never commit raw subscription/tenant/principal/resource IDs, email addresses,
access tokens, portal URLs with identifiers, or unredacted CLI output.
