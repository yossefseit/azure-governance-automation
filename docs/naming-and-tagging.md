# Naming and tagging

## Principle

Names hold stable identity; tags hold changeable operational metadata. Resource
type constraints differ, so one universal naming string is not assumed. The
pattern follows the [Cloud Adoption Framework naming guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
and [tagging guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging).

## Names

With the default `aglab` prefix:

| Resource | Pattern | Example |
| --- | --- | --- |
| Governance resource group | `rg-<prefix>-governance` | `rg-aglab-governance` |
| Action group | `ag-<prefix>-cost` | `ag-aglab-cost` |
| Budget | `<prefix>-monthly-guardrail` | `aglab-monthly-guardrail` |
| Policy assignment | `<prefix>-guardrails` | `aglab-guardrails` |
| Policy initiative | `<prefix>-baseline` | `aglab-baseline` |
| Policy definitions | `<prefix>-<purpose>` | `aglab-inherit-rg-tag` |
| Delete lock | `<prefix>-delete-protection` | `aglab-delete-protection` |

The prefix contract is exactly 3–12 lowercase ASCII letters or digits
(`^[a-z0-9]{3,12}$`). A Bicep assertion and both cleanup implementations enforce
the same contract, even where an individual Azure resource type accepts more
characters. Renaming a prefix after deployment creates a new logical resource
set; do not use a name for mutable ownership or lifecycle data.

## Tags

| Tag | Example | Purpose |
| --- | --- | --- |
| `environment` | `lab` | Lifecycle classification used by policy inheritance. |
| `owner` | `portfolio` | Non-personal accountable team/portfolio label. |
| `costCenter` | `learning` | Cost grouping label; not an accounting claim. |
| `managedBy` | `bicep` | Declares the source of configuration. |
| `portfolioLab` | `azure-governance-automation` | Safety marker checked before cleanup deletes the resource group. |
| `dataClassification` | `public-demo` | Signals that lab resources must not contain private data. |

Do not store email addresses, person names, tenant data, credentials, or other
sensitive values in tags. Tags can be visible in billing, logs, support, policy,
and inventory systems. Tag Contributor can change tags but does not grant access
to a resource's data plane.

The custom inheritance policy adds only a missing `environment` or `owner` value
from the parent resource group. An explicit resource value wins. Resource types
that do not support tags or location are outside `Indexed` evaluation.
