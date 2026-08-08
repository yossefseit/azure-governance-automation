# Design and decisions

## Scenario

A cloud learner has one personally owned Azure subscription and wants a small,
reviewable governance baseline before adding workload labs. The baseline should
make naming, ownership, location choice, access, deletion protection, and cost
visibility explicit without creating an always-running workload.

This repository implements that subscription baseline. It does not implement
an enterprise landing zone, and it does not claim management-group, tenant,
production, compliance, or runtime evidence.

## Scope boundary

```text
tenant / management groups     documented extension point only
└── personally owned subscription
    ├── subscription policy definitions, initiative, assignment, and budget
    └── rg-<prefix>-governance
        ├── Azure Monitor action group
        ├── optional group Reader assignment
        └── CanNotDelete lock
```

Azure landing zones normally separate platform and application responsibilities
across a reasonably flat management-group and subscription hierarchy. A single
lab subscription has neither the organizational ownership nor scale to prove that
model. Moving these custom definitions to a management group would require a
separate management-group deployment, assignment-scope decisions, inheritance
tests, and tenant-owner approval. The code deliberately does not fake that work.

See the [Cloud Adoption Framework guidance for resource organization](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/resource-org-management-groups)
and [Azure landing zone design principles](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-principles).

## Deployment graph

`infra/main.bicep` uses subscription scope and preserves scope boundaries through
small modules:

| Module | Scope | Responsibility |
| --- | --- | --- |
| `notification-group.bicep` | Governance resource group | Action group and optional local-only receivers |
| `subscription-budget.bicep` | Subscription | Monthly actual/forecast notifications wired to the action group |
| `policy-governance.bicep` | Subscription | Definitions, initiative, conditional assignment identity/RBAC, optional tasks |
| `resource-group-access.bicep` | Governance resource group | Optional group-based Reader assignment |
| `resource-group-lock.bicep` | Governance resource group | Optional `CanNotDelete` lock |

The implementation keeps these simple resources native instead of wrapping each
one in an Azure Verified Module. That makes subscription/resource-group scope,
identity, and dependency ordering visible for an interview-sized lab. AVM becomes
more valuable when organizational defaults, telemetry, version governance, and
repeated module consumption justify the abstraction. See the [AVM Bicep usage guidance](https://azure.github.io/Azure-Verified-Modules/usage/quickstart/bicep/).

## Policy design

The initiative has five references backed by three custom definitions:

1. Require `environment` on resource groups.
2. Require `owner` on resource groups.
3. Inherit a missing `environment` tag from the parent resource group.
4. Inherit a missing `owner` tag from the parent resource group.
5. Audit or deny resources outside an approved location list.

The required-tag and location effects default to `Audit`. Deny should follow a
compliance review, service-location review, exemption workflow, and rollback
exercise. The location definition excludes resources without a location and the
literal `global` location; this is still not proof that every Azure service used
by a future workload is compatible with the list.

The inheritance definition uses `Indexed` mode with a `Modify`/`Disabled` effect
parameter. `Disabled` is the assignment default. If deliberately changed to
`Modify`, it adds only a missing tag when the parent resource group has a
non-empty value and does not overwrite an explicit resource value. This follows
Microsoft's [tag policy pattern](https://learn.microsoft.com/en-us/azure/governance/policy/samples/pattern-tags).

`Modify` needs a managed identity for existing-resource remediation. Only when
`Modify` is selected does the assignment receive a system identity and exactly
the built-in Tag Contributor role at assignment scope. Existing resources are
not changed until a remediation task runs; bounded tasks are disabled by default
and an assertion rejects them while inheritance is Disabled. Review
[modify semantics](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify)
and [remediation access](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources).

Same-parameter `Modify` reruns retain the identity/role relationship, but the
effect is not an arbitrary lifecycle toggle. `Modify` → `Disabled` can remove the
system identity while incremental deployment retains the conditional role
assignment. A later return to `Modify` can produce a new principal and
`RoleAssignmentUpdateNotPermitted` on the stable role GUID. Full guarded cleanup
is required before this transition; see [deployment rollback](deployment.md#rollback-before-cleanup).

Policy exemptions are not created by this baseline. A real exception needs an
owner, reason, expiration, ticket/evidence reference, review process, and the
smallest possible scope. A `notScopes` list can hide resources from portal
compliance views and is not a substitute for governed exemptions.

## Budget and notification design

The subscription budget has an actual threshold at 80 percent and forecast
threshold at 100 percent. Both use the action-group resource ID in
`contactGroups`. The committed example has no receiver because an address is
personal data; a local ignored parameter can add one or more email receivers.

Budget evaluation and delivery are asynchronous. A budget is not a quota, deny
control, approval, or hard cap. It cannot make a subscription zero-cost. See
[Cost Management budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
and [Cost Management automation](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/manage-automation).

## Lock design

The governance resource group uses `CanNotDelete`, not `ReadOnly`. Authorized
operators can update resources, but deletion is blocked until the lock is removed.
Locks operate on the control plane, override normal permissions, inherit to child
resources, and can disrupt valid service operations. Cleanup deletes the exact
lock ID first. See [Azure resource lock behavior](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources).

## API versions checked

The Bicep 0.46.1 type system accepted these schemas during local compilation:

| Resource type | API version | Reference |
| --- | --- | --- |
| Policy definition/set/assignment | `2025-03-01` | Policy [definition](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2025-03-01/policydefinitions), [set](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2025-03-01/policysetdefinitions), and [assignment](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2025-03-01/policyassignments) references |
| Policy remediation | `2024-10-01` | [Remediation template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.policyinsights/2024-10-01/remediations) |
| Subscription budget | `2024-08-01` | [Budget template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.consumption/2024-08-01/budgets) |
| Action group | `2023-01-01` | [Action group template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2023-01-01/actiongroups) |
| Role assignment | `2022-04-01` | [Role assignment template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2022-04-01/roleassignments) |
| Management lock | `2020-05-01` | [Lock template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2020-05-01/locks) |
| Nested deployment cleanup | `2025-04-01` | [Deployment template reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.resources/2025-04-01/deployments) |

Compilation checks source syntax and Bicep types. Only authenticated ARM validation
can establish whether provider registration, billing offer, permissions, and
server-side policy semantics are accepted in a specific subscription.

Cross-parameter safeguards use Bicep assertions for remediation/effect coupling
and reviewer-group presence. Assertions remain experimental in Bicep 0.46.1 and
emit ARM template `languageVersion: 2.1-experimental`. The compiler emits an
expected feature warning; [Microsoft does not support experimental features for production](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-config#enable-experimental-features).
Replacing them with a supported cross-parameter validation mechanism is a
production-hardening gap.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| Full Azure landing zone accelerator | Rejected for this lab: it would obscure the learning scope and imply unverified enterprise context. |
| Management-group policy assignment | Deferred: needs tenant ownership, hierarchy, inherited-scope testing, and broader blast-radius approval. |
| Built-in tag definitions only | Custom definitions retained to expose rule structure, identity role IDs, initiative parameters, and safe effects. Built-ins should be preferred after matching requirements. |
| Deny by default | Rejected: unfamiliar subscriptions need audit evidence and exception discovery first. |
| Automatic remediation by default | Rejected: it writes to existing resources across assignment scope. |
| Tag inheritance `Modify` by default | Rejected: it creates subscription-scope tag write permission before explicit review. |
| Subscription `ReadOnly` lock | Rejected: overly disruptive and difficult to operate safely in a learning subscription. |
| Automatic shutdown on budget threshold | Rejected: budgets do not provide a reliable hard-cap mechanism; automation could cause unsafe partial shutdown. |

## Lessons learned

- Conditional Bicep resources are not removed by an incremental deployment when
  their condition becomes false. Deterministic IDs/names and guarded teardown
  are therefore part of the design, not an afterthought.
- Budget alerts provide visibility, not enforcement. Their start date must remain
  stable across reruns to avoid accidental replacement or validation drift.
- `Modify` is a coupled policy/identity/RBAC/remediation lifecycle. A safe review
  considers all four elements, including immutable role-assignment properties and
  cleanup of residual state.
