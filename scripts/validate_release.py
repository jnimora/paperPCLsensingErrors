#!/usr/bin/env python3
"""Validate the curated paperPCLsensingErrors release.

This script uses only the Python standard library. It does not modify raw data,
processed data, figures, notebooks, or provenance. It writes deterministic
validation reports under reproducibility/data/checks.
"""

from __future__ import annotations

import csv
import hashlib
import sys
from pathlib import Path
from typing import Any


EXPECTED_CFF_FIELDS = {
    "cff-version: 1.2.0",
    'version: 1.0.0',
    "type: software",
    "repository-code: https://github.com/jnimora/paperPCLsensingErrors",
}

EXPECTED_SUMMARY_ROWS = {
    "four_policy_grid": 17_280,
    "homogeneous_ties_v2": 672,
    "pcli1_broad": 30_184,
    "pcli2_broad": 30_184,
    "pcli_boundary_stress_v1": 320,
    "supporting_policy_diagnostics": 10_000,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def pdf_header_valid(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(5) == b"%PDF-"


def locate_repo() -> Path:
    candidates: list[Path] = []
    if len(sys.argv) > 1:
        candidates.append(Path(sys.argv[1]).expanduser().resolve())
    candidates.append(Path.cwd().resolve())
    candidates.append(Path(__file__).resolve().parents[1])

    for candidate in candidates:
        if (
            (candidate / "Project.toml").is_file()
            and (candidate / "Manifest.toml").is_file()
            and (candidate / "reproducibility").is_dir()
        ):
            return candidate
    raise SystemExit("Could not locate the repository root.")


def main() -> int:
    repo = locate_repo()
    repro = repo / "reproducibility"
    output_dir = repro / "data" / "checks"
    output_dir.mkdir(parents=True, exist_ok=True)

    checks: list[dict[str, Any]] = []

    def check(
        group: str,
        name: str,
        passed: bool,
        value: Any,
        expected: Any,
        note: str = "",
    ) -> None:
        checks.append(
            {
                "group": group,
                "check": name,
                "status": "PASS" if passed else "FAIL",
                "value": str(value),
                "expected": str(expected),
                "note": note,
            }
        )

    required = [
        "README.md",
        "LICENSE",
        "LICENSE-DATA",
        "LICENSES.md",
        "CITATION.cff",
        ".gitattributes",
        "docs/REPRODUCTION_GUIDE.md",
        "docs/DATA_DICTIONARY.md",
        "docs/COMPUTATIONAL_ENVIRONMENT.md",
        "docs/RELEASE_SCOPE.md",
        "docs/ZENODO_RELEASE_CHECKLIST.md",
        "scripts/validate_release.py",
        "scripts/curate_existing_results.jl",
        "scripts/windows/curate_figures.ps1",
        "scripts/provenance/capture_environment.jl",
        "reproducibility/README.md",
    ]
    for relative in required:
        path = repo / relative
        check("release files", relative, path.is_file(), path.is_file(), True)

    experiment_checks_path = (
        repro / "data" / "checks" / "all_experiment_checks_v1.csv"
    )
    rows = read_csv(experiment_checks_path)
    check("experiment checks", "row count", len(rows) == 162, len(rows), 162)
    failed_rows = [row for row in rows if row.get("status") != "PASS"]
    check(
        "experiment checks",
        "all statuses pass",
        not failed_rows,
        len(failed_rows),
        0,
    )

    summary_path = repro / "data" / "checks" / "all_experiment_summary_v1.csv"
    summary_rows = read_csv(summary_path)
    observed = {row["dataset"]: int(row["rows"]) for row in summary_rows}
    for dataset, expected_rows in EXPECTED_SUMMARY_ROWS.items():
        value = observed.get(dataset)
        check(
            "experiment summary",
            f"{dataset} rows",
            value == expected_rows,
            value,
            expected_rows,
        )

    environment_dir = repro / "provenance" / "julia_environment_used"
    environment_manifest = read_csv(
        environment_dir / "julia_environment_capture_sha256.csv"
    )
    for row in environment_manifest:
        path = environment_dir / row["File"]
        passed = (
            path.is_file()
            and path.stat().st_size == int(row["Length"])
            and sha256(path) == row["SHA256"].upper()
        )
        check(
            "environment",
            row["File"],
            passed,
            sha256(path) if path.is_file() else "missing",
            row["SHA256"].upper(),
        )

    for root_name, captured_name in [
        ("Project.toml", "Project_used.toml"),
        ("Manifest.toml", "Manifest_used.toml"),
    ]:
        root_path = repo / root_name
        captured_path = environment_dir / captured_name
        passed = (
            root_path.is_file()
            and captured_path.is_file()
            and sha256(root_path) == sha256(captured_path)
        )
        check(
            "environment",
            f"{root_name} matches capture",
            passed,
            sha256(root_path) if root_path.is_file() else "missing",
            sha256(captured_path) if captured_path.is_file() else "missing",
        )

    curation_manifest_path = (
        repro / "provenance" / "curation_v1" / "curated_outputs_sha256.csv"
    )
    curation_rows = read_csv(curation_manifest_path)
    curation_base = repro / "provenance"
    for row in curation_rows:
        path = (curation_base / row["relative_path"]).resolve()
        passed = (
            path.is_file()
            and path.stat().st_size == int(row["size_bytes"])
            and sha256(path) == row["sha256"].upper()
        )
        check(
            "curated outputs",
            row["relative_path"],
            passed,
            sha256(path) if path.is_file() else "missing",
            row["sha256"].upper(),
        )

    figure_manifest_path = (
        repro / "provenance" / "figure_curation_v1"
        / "manuscript_figures_v1.csv"
    )
    figure_rows = read_csv(figure_manifest_path)
    check(
        "figures",
        "canonical figure count",
        len(figure_rows) == 16,
        len(figure_rows),
        16,
    )
    figure_dir = repro / "figures" / "manuscript"
    for row in figure_rows:
        path = figure_dir / row["OutputFile"]
        passed = (
            path.is_file()
            and path.stat().st_size == int(row["OutputBytes"])
            and sha256(path) == row["OutputSHA256"].upper()
            and pdf_header_valid(path)
        )
        check(
            "figures",
            row["OutputFile"],
            passed,
            sha256(path) if path.is_file() else "missing",
            row["OutputSHA256"].upper(),
        )

    cff_path = repo / "CITATION.cff"
    cff_text = cff_path.read_text(encoding="utf-8") if cff_path.is_file() else ""
    for expected_line in EXPECTED_CFF_FIELDS:
        check(
            "metadata",
            expected_line,
            expected_line in cff_text,
            expected_line in cff_text,
            True,
        )
    check(
        "metadata",
        "ORCID",
        "0000-0002-2172-3983" in cff_text,
        "0000-0002-2172-3983" in cff_text,
        True,
    )
    check(
        "metadata",
        "no .zenodo.json",
        not (repo / ".zenodo.json").exists(),
        (repo / ".zenodo.json").exists(),
        False,
        "CITATION.cff is intentionally the sole GitHub/Zenodo metadata file.",
    )

    license_text = (
        (repo / "LICENSES.md").read_text(encoding="utf-8")
        if (repo / "LICENSES.md").is_file()
        else ""
    )
    check(
        "licensing",
        "MIT scope",
        "MIT License" in license_text,
        "MIT License" in license_text,
        True,
    )
    check(
        "licensing",
        "CC BY 4.0 scope",
        "Creative Commons Attribution 4.0 International" in license_text,
        "Creative Commons Attribution 4.0 International" in license_text,
        True,
    )

    checks.sort(key=lambda row: (row["group"], row["check"]))

    report_path = output_dir / "release_validation_v1.csv"
    with report_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["group", "check", "status", "value", "expected", "note"],
        )
        writer.writeheader()
        writer.writerows(checks)

    failures = [row for row in checks if row["status"] != "PASS"]
    summary = (
        "paperPCLsensingErrors release validation v1\n"
        f"Checks: {len(checks)}\n"
        f"Passed: {len(checks) - len(failures)}\n"
        f"Failed: {len(failures)}\n"
        f"All checks passed: {str(not failures).lower()}\n"
        "Raw numerical inputs modified: false\n"
        "Numerical experiments rerun: false\n"
        "Git operations performed: none\n"
    )
    (output_dir / "release_validation_summary_v1.txt").write_text(
        summary, encoding="utf-8"
    )

    print(summary, end="")
    print(f"Detailed report: {report_path}")

    if failures:
        print("\nFailed checks:")
        for row in failures:
            print(
                f"- [{row['group']}] {row['check']}: "
                f"value={row['value']}; expected={row['expected']}"
            )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
