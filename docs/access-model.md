# Access and GitHub OIDC model

## Principals and scope

| Principal | Scope | Intended rights | Status |
| --- | --- | --- | --- |
| Human lab owner | Personally owned subscription | Bootstrap federation and approve high-blast-radius changes | External prerequisite; not automated |
| Offline CI | Repository only | Build, lint, test, link/spelling/secret checks | Implemented without Azure credentials |
| Preview identity | Subscription | Read and submit deployment validate/what-if | Design only; no federated credential created |
| Deployment identity | Subscription | Write only the resource types in this baseline, including narrowly defined role assignments | Design only; no identity or role created |
| Policy assignment identity | Subscription | Built-in Tag Contributor for tag remediation | Conditional on explicit `Modify`; default identity type is `None` |
| Reviewer group | Governance resource group | Built-in Reader | Optional, disabled by default |

The stable built-in IDs used in code are:

- Tag Contributor: `4a9ae827-6dc8-4573-8ac7-8239d42aa03f`
- Reader: `acdd72a7-3385-48ef-bd42-f606fba81ae7`

They are verified in Microsoft's [built-in role reference](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles).
The code never resolves roles by localized display name.

The optional reviewer assignment name is deterministic from the governance
resource-group ID, reviewer group object ID, and Reader role ID. If access is
enabled, keep that group object ID in the ignored private parameter file even
after changing `enableReviewerAccess` back to `false`. Retain it through the
disable redeployment and guarded cleanup so the manifest continues to identify
the earlier assignment. Never commit the real object ID.

## GitHub OpenID Connect design

An authenticated GitHub workflow is intentionally not enabled before a personally
owned tenant is verified. The intended flow is:

1. A tenant administrator creates an application or user-assigned managed
   identity and a federated credential.
2. The credential subject is restricted to a protected GitHub environment, for
   example `repo:<owner>/<repository>:environment:azure-preview`, rather than all
   branches.
3. GitHub environment reviewers approve the job. The workflow has only
   `contents: read` and `id-token: write` permissions.
4. Azure Login exchanges the GitHub token for a short-lived Azure token. No
   client secret is stored.
5. Repository/environment variables hold the client, tenant, and subscription
   identifiers. They are identifiers, not secrets, but they are still kept out
   of this public codebase.
6. The script independently compares the requested subscription to
   `az account show` and stops on mismatch. It never switches context.

Follow GitHub's [Azure OIDC configuration](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)
and Microsoft's [GitHub OIDC guidance](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).
Production use should also pin third-party actions to immutable commit SHAs and
protect the environment with reviewers and branch rules.

## Deployment permission boundary

The template writes these control-plane types:

```text
Microsoft.Resources/deployments
Microsoft.Resources/subscriptions/resourceGroups
Microsoft.Insights/actionGroups
Microsoft.Consumption/budgets
Microsoft.Authorization/policyDefinitions
Microsoft.Authorization/policySetDefinitions
Microsoft.Authorization/policyAssignments
Microsoft.Authorization/roleAssignments
Microsoft.Authorization/locks
Microsoft.PolicyInsights/remediations
```

The exact candidate custom-role action list is recorded in
[`deployment-permissions.json`](deployment-permissions.json). It is not a role
definition and has not been assigned or Azure validated. Cleanup's direct
resource-group inventory specifically needs
`Microsoft.Resources/subscriptions/resourceGroups/resources/read`, whose purpose
is listed in Microsoft's [management/governance provider operations](https://learn.microsoft.com/en-us/azure/role-based-access-control/permissions/management-and-governance).

Role assignment writes are privileged. A safer real implementation separates
bootstrap from routine preview:

- **Routine pull requests:** offline CI only; optionally federated validate and
  what-if through a preview identity with no deployment job.
- **Approved baseline deployment:** protected environment and a deployment
  identity limited to this subscription and these resource providers.
- **RBAC bootstrap:** a human eligible through least privilege grants the two
  deterministic assignments, or grants the deployment identity time-limited
  permission to create only approved assignments. Do not leave Owner permanently
  assigned to CI.

Azure role conditions can narrow role-assignment administration where supported,
but their correctness must be tenant-tested. This repository does not invent a
condition it has not validated. Review [Azure RBAC best practices](https://learn.microsoft.com/en-us/azure/role-based-access-control/best-practices).

## Separation-of-duties limits

One-person lab ownership cannot demonstrate organizational approval, access
reviews, privileged identity management, or break-glass custody. The scripts and
GitHub environment model make approval points visible, but they are not evidence
that enterprise segregation of duties exists.
