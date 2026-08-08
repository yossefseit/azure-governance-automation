#!/usr/bin/env python3
"""Dependency-free repository invariants for the governance lab."""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
SCAN_EXCLUDED_PARTS = {".git", "node_modules", "dist", "bin", "coverage"}


def fail(message: str) -> None:
    raise AssertionError(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def is_scan_excluded(path: Path) -> bool:
    relative = path.relative_to(ROOT)
    return any(part in SCAN_EXCLUDED_PARTS for part in relative.parts)


def repository_files(pattern: str = "*") -> list[Path]:
    return [
        path
        for path in ROOT.rglob(pattern)
        if path.is_file() and not is_scan_excluded(path)
    ]


def test_required_files() -> None:
    required = {
        ".github/workflows/ci.yml",
        "AGENTS.md",
        "LICENSE",
        "README.md",
        "SECURITY.md",
        "architecture/architecture.mmd",
        "architecture/architecture.svg",
        "docs/access-model.md",
        "docs/cleanup.md",
        "docs/cost.md",
        "docs/deployment.md",
        "docs/design.md",
        "docs/roadmap.md",
        "docs/testing.md",
        "docs/threat-model.md",
        "docs/troubleshooting.md",
        "docs/validation.md",
        "evidence/evidence-template.md",
        "infra/bicepconfig.json",
        "infra/environments/lab.example.bicepparam",
        "infra/main.bicep",
        "scripts/Cleanup.ps1",
        "scripts/cleanup.sh",
        "scripts/Deploy.ps1",
        "scripts/deploy.sh",
        "scripts/Validate.ps1",
        "scripts/validate.sh",
        "scripts/WhatIf.ps1",
        "scripts/what-if.sh",
        "tests/compiled-template.py",
    }
    missing = sorted(path for path in required if not (ROOT / path).is_file())
    if missing:
        fail(f"Missing required files: {missing}")


def test_json_files() -> None:
    for path in repository_files("*.json"):
        json.loads(path.read_text(encoding="utf-8"))


def test_repository_scan_exclusions() -> None:
    excluded_examples = [
        ROOT / ".git" / "index",
        ROOT / "node_modules" / "package" / "index.js",
        ROOT / "dist" / "compiled.json",
        ROOT / "bin" / "tool",
        ROOT / "coverage" / "report.json",
    ]
    if not all(is_scan_excluded(path) for path in excluded_examples):
        fail("Repository scanners must exclude VCS metadata and generated directories.")
    if is_scan_excluded(ROOT / "README.md"):
        fail("Repository scanners must not exclude tracked source files.")


def test_identifier_hygiene() -> None:
    allowed_role_ids = {
        "4a9ae827-6dc8-4573-8ac7-8239d42aa03f",
        "acdd72a7-3385-48ef-bd42-f606fba81ae7",
    }
    guid_pattern = re.compile(
        r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
    )
    email_pattern = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)

    for path in repository_files():
        if path.suffix.lower() in {".svg"}:
            continue
        text = path.read_text(encoding="utf-8")
        unexpected = sorted(set(guid_pattern.findall(text)) - allowed_role_ids)
        if unexpected:
            fail(f"Unexpected GUID-shaped identifier in {path.relative_to(ROOT)}: {unexpected}")
        if email_pattern.search(text):
            fail(f"Email-shaped value found in {path.relative_to(ROOT)}")

    parameters = read("infra/environments/lab.example.bicepparam")
    if "reviewerGroupObjectId = ''" not in parameters or "budgetContactEmails = []" not in parameters:
        fail("Committed parameters must keep principal and receiver values empty.")


def test_bicep_safety_and_scope() -> None:
    main = read("infra/main.bicep")
    policy = read("infra/modules/policy-governance.bicep")
    budget = read("infra/modules/subscription-budget.bicep")
    access = read("infra/modules/resource-group-access.bicep")
    lock = read("infra/modules/resource-group-lock.bicep")

    expectations = {
        "subscription target": "targetScope = 'subscription'" in main,
        "remediation disabled": "param createRemediationTasks bool = false" in main,
        "reviewer disabled": "param enableReviewerAccess bool = false" in main,
        "audit location default": "param locationPolicyEffect string = 'Audit'" in main,
        "audit tag default": "param requiredTagPolicyEffect string = 'Audit'" in main,
        "inheritance disabled": "param inheritancePolicyEffect string = 'Disabled'" in main,
        "prefix character assertion": "assert prefixIsLowerAlphanumeric = empty(invalidPrefixCharacters)" in main,
        "remediation assertion": "assert remediationRequiresModify" in main,
        "reviewer assertion": "assert reviewerGroupProvided" in main,
        "cleanup marker": "portfolioLab: labMarker" in main,
        "cleanup manifest schema": "schemaVersion: '1.2'" in main,
        "subscription deployment names": all(
            name in main
            for name in ["subscription-budget", "policy-governance"]
        ),
        "resource-group deployment names": all(
            name in main
            for name in ["notification-group", "reviewer-access", "resource-lock"]
        ),
        "conditional identity": "type: inheritancePolicyEffect == 'Modify' ? 'SystemAssigned' : 'None'" in policy,
        "conditional remediation role": "if (inheritancePolicyEffect == 'Modify')" in policy,
        "deterministic remediation role output": (
            "output remediationRoleAssignmentResourceId string = remediationRoleAssignmentResourceId"
            in policy
        ),
        "deterministic remediation outputs": (
            "output remediationResourceIds array = remediationResourceIds" in policy
        ),
        "bounded remediation": "resourceCount: 50" in policy and "parallelDeployments: 5" in policy,
        "tag role": "4a9ae827-6dc8-4573-8ac7-8239d42aa03f" in policy,
        "reader role": "acdd72a7-3385-48ef-bd42-f606fba81ae7" in access,
        "group principal": "principalType: 'Group'" in access,
        "deterministic reviewer output": (
            "output roleAssignmentResourceId string = roleAssignmentResourceId" in access
        ),
        "delete lock": "level: 'CanNotDelete'" in lock,
        "deterministic lock output": "output lockResourceId string = lockResourceId" in lock,
        "actual budget": "thresholdType: 'Actual'" in budget,
        "forecast budget": "thresholdType: 'Forecasted'" in budget,
        "action group wiring": "contactGroups:" in budget,
    }
    failed = sorted(name for name, result in expectations.items() if not result)
    if failed:
        fail(f"Bicep safety/scope invariant failed: {failed}")


def test_parameter_contracts() -> None:
    main = read("infra/main.bicep")
    parameters = read("infra/environments/lab.example.bicepparam")
    bash_cleanup = read("scripts/cleanup.sh")
    ps_cleanup = read("scripts/Cleanup.ps1")

    prefix_pattern = re.compile(r"^[a-z0-9]{3,12}$")
    accepted = ["abc", "aglab", "lab2026", "abcdefghijkl"]
    rejected = ["ab", "abcdefghijklm", "AgLab", "ag-lab", "ag_lab", "ag lab"]
    if not all(prefix_pattern.fullmatch(value) for value in accepted):
        fail("Test fixture contains a valid prefix rejected by the lifecycle contract.")
    if any(prefix_pattern.fullmatch(value) for value in rejected):
        fail("Invalid prefix was accepted by the lifecycle contract.")

    prefix_checks = {
        "allowed character set": "abcdefghijklmnopqrstuvwxyz0123456789" in main,
        "character comprehension": "range(0, length(prefix))" in main
        and "substring(prefix, prefixIndex, 1)" in main,
        "invalid character filter": "filter(prefixCharacters" in main,
        "Bicep assertion": (
            "assert prefixIsLowerAlphanumeric = empty(invalidPrefixCharacters)" in main
        ),
        "Bash cleanup pattern": "^[a-z0-9]{3,12}$" in bash_cleanup,
        "PowerShell cleanup pattern": "^[a-z0-9]{3,12}$" in ps_cleanup,
    }
    failed_prefix_checks = sorted(
        name for name, result in prefix_checks.items() if not result
    )
    if failed_prefix_checks:
        fail(f"Prefix contract drifted across Bicep/cleanup: {failed_prefix_checks}")

    if "utcNow(" in main:
        fail("budgetStartDate must not drift through utcNow on redeployment.")
    if not re.search(r"^param budgetStartDate string\s*$", main, re.M):
        fail("budgetStartDate must be an explicit required Bicep parameter.")
    date_match = re.search(
        r"^param budgetStartDate = '([^']+)'\s*$", parameters, re.M
    )
    if not date_match:
        fail("Committed parameters need one stable budgetStartDate example.")
    budget_start = datetime.fromisoformat(
        date_match.group(1).replace("Z", "+00:00")
    )
    if (
        budget_start.utcoffset() is None
        or budget_start.utcoffset().total_seconds() != 0
        or budget_start.day != 1
        or any((budget_start.hour, budget_start.minute, budget_start.second))
    ):
        fail("Committed budgetStartDate must be midnight UTC on the first day of a month.")


def test_script_guards_and_parity() -> None:
    common_bash = read("scripts/lib/common.sh")
    common_ps = read("scripts/Common.ps1")
    bash_deploy = read("scripts/deploy.sh")
    ps_deploy = read("scripts/Deploy.ps1")
    bash_cleanup = read("scripts/cleanup.sh")
    ps_cleanup = read("scripts/Cleanup.ps1")
    bash_guards = read("tests/shell-guards.sh")
    ps_guards = read("tests/powershell-guards.ps1")
    mock_az = read("tests/fixtures/az")

    script_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in list((ROOT / "scripts").glob("*.sh"))
        + list((ROOT / "scripts").glob("*.ps1"))
        + list((ROOT / "scripts/lib").glob("*.sh"))
    )
    forbidden_switch = "az " + "account " + "set"
    if forbidden_switch in script_text.lower():
        fail("Lifecycle scripts must never switch the Azure subscription.")

    checks = {
        "Bash exact context": "assert_subscription_context" in common_bash,
        "PowerShell exact context": "Test-AzureSubscriptionContext" in common_ps,
        "Bash deploy confirmation": "DEPLOY:${deployment_name}" in bash_deploy,
        "PowerShell deploy confirmation": "DEPLOY:$DeploymentName" in ps_deploy,
        "Bash mandatory deploy gates": bash_deploy.index("deployment sub validate")
        < bash_deploy.index("deployment sub what-if")
        < bash_deploy.index("read -r final_confirmation")
        < bash_deploy.index("deployment sub create"),
        "PowerShell mandatory deploy gates": ps_deploy.index("deployment sub validate")
        < ps_deploy.index("deployment sub what-if")
        < ps_deploy.index("Read-Host")
        < ps_deploy.index("deployment sub create"),
        "Bash cleanup confirmation": "DELETE:${deployment_name}" in bash_cleanup,
        "PowerShell cleanup confirmation": "DELETE:$DeploymentName" in ps_cleanup,
        "Bash RG marker": "portfolioLab" in bash_cleanup,
        "PowerShell RG marker": "portfolioLab" in ps_cleanup,
        "Bash RG resource inventory": "az resource list" in bash_cleanup,
        "PowerShell RG resource inventory": "'resource', 'list'" in ps_cleanup,
        "Bash descendant RBAC inventory": "--all" in bash_cleanup
        and "unexpected descendant-scope assignment" in bash_cleanup,
        "PowerShell descendant RBAC inventory": "'--all'" in ps_cleanup
        and "unexpected descendant-scope assignment" in ps_cleanup,
        "Bash explicit action-group delete": (
            "delete_resource_id \"${action_group_id}\" '2023-01-01'" in bash_cleanup
        ),
        "PowerShell explicit action-group delete": (
            "$ids.actionGroup -ApiVersion '2023-01-01'" in ps_cleanup
        ),
        "Bash subscription module cleanup": "subscription_deployment_ids" in bash_cleanup
        and "'2025-04-01' 'subscription module deployment record'" in bash_cleanup,
        "PowerShell subscription module cleanup": "$subscriptionDeploymentIds" in ps_cleanup
        and "-ApiVersion '2025-04-01'" in ps_cleanup,
        "Bash group-absent resume": "get_resource_group_presence" in bash_cleanup,
        "PowerShell group-absent resume": "Test-ResourceGroupPresence" in ps_cleanup,
        "Bash exact cleanup types": "expected_policy_assignment_id" in bash_cleanup,
        "PowerShell exact cleanup types": "expectedPolicyAssignmentId" in ps_cleanup,
        "Bash marker before delete": bash_cleanup.index("actual_marker=")
        < bash_cleanup.index("delete_resource_id \"${lock_id}\""),
        "PowerShell marker before delete": ps_cleanup.index("$resourceGroup.tags.portfolioLab")
        < ps_cleanup.index("$ids.lock -ApiVersion"),
        "Bash active cloud endpoint": "management.azure.com" not in bash_cleanup,
        "PowerShell active cloud endpoint": "management.azure.com" not in ps_cleanup,
        "Bash scope base": "subscription_base" in bash_cleanup,
        "PowerShell scope base": "subscriptionBase" in ps_cleanup,
        "Bash lock-first order": bash_cleanup.index("delete_resource_id \"${lock_id}\"")
        < bash_cleanup.index("delete_resource_id \"${policy_assignment_id}\""),
        "PowerShell lock-first order": ps_cleanup.index("$ids.lock -ApiVersion")
        < ps_cleanup.index("$ids.policyAssignment -ApiVersion"),
        "Bash non-404 inventory guard test": "error-with-incidental-404" in bash_guards,
        "PowerShell non-404 inventory guard test": (
            "$env:MOCK_REST_GET_MODE = 'error-with-incidental-404'" in ps_guards
        ),
        "Bash complete cleanup order test": "expected_mutations=(" in bash_guards,
        "PowerShell complete cleanup order test": "$expectedMutations = @(" in ps_guards,
        "Mock distinguishes inventory errors": (
            "Simulated resource inventory authorization failure." in mock_az
        ),
    }
    failed = sorted(name for name, result in checks.items() if not result)
    if failed:
        fail(f"Lifecycle guard/parity invariant failed: {failed}")


def test_readme_truth_boundary() -> None:
    readme = read("README.md")
    design = read("docs/design.md")
    deployment = read("docs/deployment.md")
    cleanup = read("docs/cleanup.md")
    required_phrases = [
        "not a full enterprise landing zone",
        "No authenticated ARM",
        "does **not** stop or approve spending",
        "Pending first workflow run",
        "Pending live teardown",
    ]
    missing = [phrase for phrase in required_phrases if phrase not in readme]
    if missing:
        fail(f"README evidence boundary is missing: {missing}")
    if "languageVersion: 2.1-experimental" not in design:
        fail("Design documentation must name the compiler's exact languageVersion.")
    if "languageVersion: 2.1-experimental" not in readme:
        fail("README must use the compiler's exact languageVersion wording.")
    if not re.search(r"retain its original private group\s+object ID", deployment):
        fail("Deployment rollback must preserve the reviewer assignment address.")
    if "retain that same object ID privately" not in cleanup:
        fail("Cleanup must document reviewer-principal retention.")
    lifecycle_docs = "\n".join([readme, design, deployment, cleanup])
    required_lifecycle_phrases = [
        "Modify` → `Disabled` → `Modify",
        "RoleAssignmentUpdateNotPermitted",
        "full guarded cleanup",
    ]
    missing_lifecycle = [
        phrase for phrase in required_lifecycle_phrases if phrase not in lifecycle_docs
    ]
    if missing_lifecycle:
        fail(f"Modify identity lifecycle warning is incomplete: {missing_lifecycle}")
    if re.search(r"Modify.{0,80}(?:toggle|transition).{0,80}idempotent", lifecycle_docs, re.I | re.S):
        fail("Documentation must not claim the Modify identity toggle is idempotent.")


def test_local_markdown_links() -> None:
    link_pattern = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
    missing: list[str] = []
    for path in repository_files("*.md"):
        text = path.read_text(encoding="utf-8")
        for raw_target in link_pattern.findall(text):
            target = raw_target.strip().split()[0].strip("<>")
            if target.startswith(("http://", "https://", "#", "mailto:")):
                continue
            local_target = unquote(target.split("#", 1)[0])
            if not local_target:
                continue
            resolved = (path.parent / local_target).resolve()
            if not resolved.exists():
                missing.append(f"{path.relative_to(ROOT)} -> {target}")
    if missing:
        fail(f"Broken local Markdown links: {missing}")


def test_svg_accessibility() -> None:
    svg_path = ROOT / "architecture/architecture.svg"
    tree = ET.parse(svg_path)
    root = tree.getroot()
    namespace = {"svg": "http://www.w3.org/2000/svg"}
    if root.attrib.get("role") != "img" or not root.attrib.get("viewBox"):
        fail("Architecture SVG needs role=img and a viewBox.")
    if root.find("svg:title", namespace) is None or root.find("svg:desc", namespace) is None:
        fail("Architecture SVG needs title and description elements.")


def test_workflow_is_offline_and_pinned() -> None:
    workflow = read(".github/workflows/ci.yml")
    uses = re.findall(r"^\s*uses:\s*([^\s#]+)", workflow, re.M)
    unpinned = [value for value in uses if not re.search(r"@[0-9a-f]{40}$", value)]
    if unpinned:
        fail(f"Workflow actions are not pinned to immutable SHAs: {unpinned}")
    if "id-token: write" in workflow or "azure/login" in workflow.lower():
        fail("Repository validation CI must remain offline and request no Azure token.")
    if "contents: read" not in workflow:
        fail("CI must declare read-only contents permission.")
    expected_checkout = (
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
    )
    if expected_checkout not in workflow:
        fail("CI must use the reviewed actions/checkout v7.0.1 commit.")


TESTS = [
    test_required_files,
    test_json_files,
    test_repository_scan_exclusions,
    test_identifier_hygiene,
    test_bicep_safety_and_scope,
    test_parameter_contracts,
    test_script_guards_and_parity,
    test_readme_truth_boundary,
    test_local_markdown_links,
    test_svg_accessibility,
    test_workflow_is_offline_and_pinned,
]


def main() -> int:
    failures = 0
    for test in TESTS:
        try:
            test()
        except Exception as error:  # noqa: BLE001 - report all independent checks
            failures += 1
            print(f"FAIL {test.__name__}: {error}", file=sys.stderr)
        else:
            print(f"PASS {test.__name__}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
