#!/usr/bin/env python3
"""Check safety contracts in the compiled ARM template."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Iterator


def walk(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: compiled-template.py COMPILED_ARM_JSON")

    template = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if template.get("languageVersion") != "2.1-experimental":
        raise AssertionError(
            "The documented assertion build must emit languageVersion 2.1-experimental."
        )

    cleanup_manifest = template.get("outputs", {}).get("cleanupManifest", {})
    cleanup_value = cleanup_manifest.get("value", {})
    if cleanup_value.get("schemaVersion") != "1.2":
        raise AssertionError("Compiled cleanup manifest schema must remain 1.2.")

    expected_subscription_deployments = [
        "[format('{0}-subscription-budget', parameters('prefix'))]",
        "[format('{0}-policy-governance', parameters('prefix'))]",
    ]
    expected_resource_group_deployments = [
        "[format('{0}-notification-group', parameters('prefix'))]",
        "[format('{0}-reviewer-access', parameters('prefix'))]",
        "[format('{0}-resource-lock', parameters('prefix'))]",
    ]
    deployment_names = cleanup_value.get("deploymentNames", {})
    if deployment_names.get("subscriptionModules") != expected_subscription_deployments:
        raise AssertionError("Compiled manifest has unexpected subscription module names.")
    if deployment_names.get("resourceGroupModules") != expected_resource_group_deployments:
        raise AssertionError("Compiled manifest has unexpected resource-group module names.")

    raw_resources = template.get("resources", {})
    resources = raw_resources.values() if isinstance(raw_resources, dict) else raw_resources
    actual_module_names = {
        item.get("name")
        for item in resources
        if item.get("type") == "Microsoft.Resources/deployments"
    }
    expected_module_names = set(
        expected_subscription_deployments + expected_resource_group_deployments
    )
    if actual_module_names != expected_module_names:
        raise AssertionError(
            "Compiled nested deployment names drifted from the cleanup manifest."
        )

    assertions = template.get("asserts", {})
    expected_assertions = {
        "prefixIsLowerAlphanumeric",
        "remediationRequiresModify",
        "reviewerGroupProvided",
    }
    missing_assertions = expected_assertions - assertions.keys()
    if missing_assertions:
        raise AssertionError(
            f"Compiled template is missing assertions: {sorted(missing_assertions)}"
        )
    prefix_assertion = assertions["prefixIsLowerAlphanumeric"]
    if "empty(variables('invalidPrefixCharacters'))" not in prefix_assertion:
        raise AssertionError(
            "Compiled prefix assertion no longer rejects invalid characters."
        )

    budget_parameter = template.get("parameters", {}).get("budgetStartDate", {})
    if budget_parameter.get("type") != "string" or "defaultValue" in budget_parameter:
        raise AssertionError(
            "budgetStartDate must compile as a required string with no dynamic default."
        )

    remediation_roles = [
        item
        for item in walk(template)
        if item.get("type") == "Microsoft.Authorization/roleAssignments"
        and item.get("properties", {}).get("principalType") == "ServicePrincipal"
    ]
    if len(remediation_roles) != 1:
        raise AssertionError(
            "Expected exactly one conditional policy remediation role assignment."
        )
    role = remediation_roles[0]
    principal_expression = role.get("properties", {}).get("principalId", "")
    expected_condition = "equals(parameters('inheritancePolicyEffect'), 'Modify')"
    if expected_condition not in role.get("condition", ""):
        raise AssertionError(
            "Policy remediation role assignment must remain conditional on Modify."
        )
    if not principal_expression.startswith("[if(") or "disabledPrincipalId" not in principal_expression:
        raise AssertionError(
            "Conditional principal reference is not protected by a lazy ARM if expression."
        )

    nested_outputs: dict[str, list[str]] = {}
    for resource in resources:
        if resource.get("type") != "Microsoft.Resources/deployments":
            continue
        outputs = resource.get("properties", {}).get("template", {}).get("outputs", {})
        for output_name, output in outputs.items():
            nested_outputs.setdefault(output_name, []).append(output.get("value"))

    deterministic_candidates = {
        "lockResourceId": "variables('lockResourceId')",
        "roleAssignmentResourceId": "variables('roleAssignmentResourceId')",
        "remediationRoleAssignmentResourceId": (
            "variables('remediationRoleAssignmentResourceId')"
        ),
        "remediationResourceIds": "variables('remediationResourceIds')",
    }
    for output_name, expected_expression in deterministic_candidates.items():
        values = nested_outputs.get(output_name, [])
        if len(values) != 1 or expected_expression not in (values[0] or ""):
            raise AssertionError(
                f"{output_name} must remain a deterministic cleanup candidate "
                "when its optional resource is disabled."
            )
        if (values[0] or "").startswith("[if("):
            raise AssertionError(
                f"{output_name} must not disappear behind a conditional output."
            )

    print(
        "PASS compiled ARM assertions, lazy identity reference, and deterministic "
        "cleanup outputs and deployment names."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
