# Live-evidence roadmap

All items below require a verified personally owned Azure subscription, explicit
cost approval, and sanitized evidence. They are not complete.

1. Record Azure CLI/Bicep versions and target billing currency privately.
2. Run authenticated ARM validation and store only the redacted result summary.
3. Review full what-if for exact policy, role, budget, lock, and resource-group
   changes.
4. Deploy with Audit effects, inheritance/remediation Disabled, and one approved action receiver.
5. Observe policy assignment and RBAC propagation.
6. Test required tags and location Audit with controlled, no-workload resources.
7. Separately approve `Modify`, verify conditional identity/RBAC, and confirm
   explicit resource tags are preserved while missing values inherit.
8. Inventory a bounded remediation target set, approve, enable tasks, and compare
   before/after metadata.
9. Verify optional group Reader positive/negative permissions if that feature is
   enabled.
10. Confirm the lock prevents controlled resource-group deletion and still permits
    expected updates.
11. Observe a genuine budget notification without creating artificial spend.
12. Run guarded cleanup, observe deletion, and check delayed cost data later.
13. Update the README matrix and portfolio only for evidence actually produced.

Future code tracks, after this baseline is proven:

- management-group variant with explicit inheritance/exemption testing;
- Azure Monitor incident-response lab with KQL, actionable alerts, and runbooks;
- backup/restore lab with measured recovery evidence;
- substantial Terraform implementation with remote-state, drift, import, and
  Bicep comparison—not a syntax-only translation.
