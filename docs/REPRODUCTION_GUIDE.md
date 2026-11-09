# Reproduction guide

## 1. Supported environment

The supported environment is the repository-root Julia project:

```text
Project.toml
Manifest.toml
```

It was captured under Julia 1.12.6. The recent office-PC notebook workflow used
12 Julia threads and 6 BLAS threads. Exact package versions are pinned in
`Manifest.toml`.

Instantiate the project from the repository root:

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

## 2. Validation levels

### Level A — Validate the archived release

```bash
python scripts/validate_release.py
```

This is the recommended first check. It verifies:

- all 162 previously generated experiment checks are `PASS`;
- processed-data files match their SHA-256 manifest;
- the root Julia project matches the captured environment;
- all 16 canonical manuscript figures match their curation manifest;
- required licenses, citation metadata, documentation, and scripts are present.

This check does not rerun the expensive experiments.

### Level B — Rebuild processed tables from immutable raw outputs

```bash
julia --project=. scripts/curate_existing_results.jl .
```

This script reads the archived raw data, reconstructs the canonical processed
tables, and reruns the 162 data-integrity and consistency checks. It does not
rerun simulations or PCLI metric grids.

### Level C — Rebuild the canonical figure directory

On Windows with MiKTeX available:

```powershell
powershell -ExecutionPolicy Bypass -File `
  ".\scripts\windows\curate_figures.ps1"
```

This copies 14 validated PDFs and recompiles the two recovered PGFPlotsX
standalone TeX sources. It does not recompute numerical coordinates.

### Level D — Full numerical reruns

The recent revision experiments are organized around:

```text
reproducibility/notebooks/revised_experiments_seven_policy_pilot_clean_v4.ipynb
reproducibility/src/benchmark_indices_rkappa_v4.jl
reproducibility/src/seven_policy_pilot_rkappa_v1.jl
reproducibility/src/four_policy_runner_rkappa_v1.jl
reproducibility/src/four_policy_full_grid_checkpointed_v1.jl
reproducibility/src/homogeneous_tie_grid_lexicographic_random_v2.jl
reproducibility/src/pcli_boundary_stress_v1.jl
```

Open the v4 notebook with a Julia kernel attached to the repository project.
The notebook defines the metric callbacks and loads the checkpointed runners.

The older broad PCLI1 and PCLI2 experiments are preserved with their complete
checkpoint chunks and final tables under:

```text
reproducibility/data/raw/pcli_broad/pcli1/
reproducibility/data/raw/pcli_broad/pcli2/
```

Their original code and notebook are retained under:

```text
reproducibility/provenance/mac_legacy/
```

The legacy MacBook directory did not contain a pinned Julia project. Therefore,
the release treats the imported raw outputs and their file-level hashes as the
primary archival record, while the root Julia project is the supported current
environment.

## 3. Experiment map

### Broad PCLI1

- 30,184 parameter tuples.
- 59 checkpoint chunks.
- Endpoint-dense 121 by 121 state/threshold grid.
- Final raw aggregate: `all_results_sorted.csv`.
- Canonical processed aggregate:
  `pcli1_broad_all_results_p01.csv`.

### Broad PCLI2

- 30,184 parameter tuples.
- 59 checkpoint chunks.
- Uniform core grid plus side padding.
- Three raw orderings of the same rows.
- Canonical processed aggregate:
  `pcli2_broad_all_results_p01.csv`.

### Boundary stress

- 320 endpoint-focused coarse tuples.
- Separate PCLI1 and PCLI2 refinements of the worst coarse cases.
- Six raw CSV outputs under `data/raw/pcli_boundary_stress/`.

### Four-policy heterogeneous grid

- 12 scenarios.
- 4,320 cases.
- 17,280 policy rows.
- Policies: MP index, myopic, LWZ4, and capacity-filled Lagrangian priority.
- The Lagrangian benchmark is stored as conditional, not globally certified.

### Homogeneous tie diagnostic

- 168 cases.
- 672 rows.
- Final v2 experiment compares the lexicographic MP implementation with the
  corresponding randomized belief-based rule and records exact sample-path
  agreement.

## 4. Randomness and pairing

Simulation files record their seeds. The policy experiments use common random
numbers and paired comparisons. Preserve `case_id`, `seed`, and `replication`
columns when performing downstream analyses.

## 5. Output immutability

Do not edit files under `reproducibility/data/raw/`. Derived tables belong
under `reproducibility/data/processed/`. The `.gitattributes` file disables
line-ending normalization for archived data, notebooks, figures, and
provenance so that the recorded SHA-256 hashes remain meaningful.

## Submitted revision

The submitted paper uses the 16 PDFs in `reproducibility/figures/submitted/`.
`figures.csv` gives their manuscript labels, page numbers and SHA-256 hashes.
The validator checks these files together with the August release figures.
Main Figures 3 and 4 use revised Lagrangian terminology. The historical
`scripts/regenerate_figures_3_4_final_terminology_v2.py` uses PyMuPDF on the
earlier PDFs. Use a separate output directory when invoking it. The submitted
Figure 4 carries the suffix `_v2`. The submitted PDFs are the reference
for the final artwork. Earlier coordinate sources for supplementary Figures
S6, S7, S8, S9 and S12 are under `reproducibility/figures/source/mac_legacy/`.

### Running the revision notebook with its local inputs

The notebook resolves Julia includes relative to its working directory.
From the repository root, the following Python commands assemble a fresh
run directory next to the repository. Run these in a Python interpreter.

```python
from pathlib import Path
from shutil import copy2

repo = Path.cwd()
run = repo.parent / "sensing-errors-notebook-run"
run.mkdir()
repro = repo / "reproducibility"
for source in (repro / "src").glob("*.jl"):
    copy2(source, run)
copy2(repro / "provenance/mac_legacy/pcli1_pilot.jl", run)
copy2(repro / "notebooks/revised_experiments_seven_policy_pilot_clean_v4.ipynb", run)
copy2(repro / "data/supporting/pilot_diagnostics/five_policy_grid_s01_N100_T700_n1000_v1.csv", run)
```

Open the copied notebook with the run directory as its working directory
and the repository-root Julia environment active. The executed cells retain
the analyses used in the paper. Later exploratory cells also refer to older
scratch outputs. For the published policy comparisons use the four-policy
scenario runner and the v2 homogeneous-tie runner. The original five-policy
smoke checkpoint supplies the reused cases for scenario 1 at N = 100.
