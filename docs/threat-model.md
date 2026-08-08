# Threat model

## Assets and trust boundaries

Protected assets are Azure governance configuration, subscription selection,
role assignments, budget receivers, deployment output, and the integrity of
cleanup targets. Trust boundaries exist between a developer workstation, GitHub
Actions, GitHub's token issuer, Microsoft Entra ID, Azure Resource Manager, and
the target subscription.

No workload data plane exists in this lab. That reduces runtime attack surface;
it does not remove control-plane risk.

## Threats and controls

| Threat | Consequence | Control in this repository | Residual risk / live test |
| --- | --- | --- | --- |
| Wrong Azure subscription | Governance writes or deletion in an employer/customer scope | Mandatory explicit ID, exact `az account show` comparison, no context switch | Operator can authenticate to the wrong tenant and supply that ID; ownership remains a human gate |
| Long-lived GitHub Azure secret | Credential theft and replay | OIDC design, offline default CI, no cloud credentials in workflow | Federation is not provisioned or tested |
| Over-privileged deployment principal | Subscription-wide configuration or RBAC abuse | Resource-type action inventory, protected deployment boundary, no permanent Owner recommendation | Custom role and conditions require tenant validation |
| Policy `Deny` blocks legitimate services | Deployment outage or operational friction | Audit defaults, documented exception/rollout requirement | Service aliases and location behavior need real compliance review |
| Modify remediation overwrites metadata | Ownership/cost attribution damage | Inheritance, identity RBAC, and tasks disabled by default; explicit opt-in adds only missing tags; bounded count/parallelism | Policy evaluation and a controlled test resource are pending |
| Malicious/tampered cleanup output | Cross-scope or same-subscription deletion | Prefix-derived IDs; strict manifest/module-name sets; allowlisted RG resource, lock, descendant-RBAC, and deployment inventories; markers before mutation and group delete | A principal able to replace deployment output, resources, and markers remains high privilege; live race behavior is untested |
| Management lock blocks legitimate recovery | Teardown or service operation fails | `CanNotDelete`, not `ReadOnly`; cleanup removes exact lock first | Lock interactions vary by service and need live teardown evidence |
| Budget creates false safety | Unnoticed cost or delayed alert | Repeated warning that budgets are asynchronous alerts, empty receiver made visible | Billing latency, currency, and receiver delivery are untested |
| Receiver leaks personal data | Address appears in public history or ARM output | Committed parameter has no receiver; local parameter is ignored | Operator must keep local files and screenshots sanitized |
| Pull-request code exfiltrates OIDC token | Subscription compromise | No authenticated PR workflow; protected environment design | Future workflow must restrict fork/PR execution and pin actions |
| Dependency/action supply-chain compromise | CI code execution | Minimal toolchain; actions pinned to immutable SHAs; read-only CI permissions | Hosted runner and downloaded package trust remain |

## Abuse cases to test before enabling deployment CI

- A mismatched subscription ID stops before any deployment command.
- Missing or incorrect deploy/cleanup confirmation stops before mutation.
- A cleanup manifest with an off-subscription ID stops before the first delete.
- A resource group without the exact `portfolioLab` tag is never group-deleted.
- An unexpected direct resource, lock, group/child role assignment, or group
  deployment record stops before mutation; final drift stops before group delete.
- A pull request cannot request an Azure identity token.
- The deployment identity cannot create arbitrary broad role assignments.
- Deny effects have an approved rollback to Audit or Disabled.

Offline Bash and PowerShell tests cover subscription mismatch, missing
confirmation, incorrect markers, strict inventory errors/drift, optional absence,
late-stage resume, and exact delete ordering. The failure cases prove no mutation
is reached when preflight is untrusted, while final drift proves the group itself
is retained after earlier exact deletions. Off-subscription manifest tampering,
Azure RBAC, policy, OIDC, concurrent Azure races, and live teardown tests remain
pending.
