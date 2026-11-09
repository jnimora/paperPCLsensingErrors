# paperPCLsensingErrors

Code, data, notebooks, validation records, and manuscript figures for:

> **Restless bandits with one-sided binary feedback: PCL-indexability analysis and computation**

Author: **José Niño-Mora**, Universidad Carlos III de Madrid<br>
ORCID: **0000-0002-2172-3983**

## Scientific scope

The associated paper studies a partially observed restless-bandit model with
binary latent states and one-sided binary feedback. The repository
implements the partial-conservation-law (PCL) calculations, marginal metrics,
marginal-productivity (MP) index computations, numerical tests, policy
comparisons, and figure generation used in the revision.

The analytical and numerical scope must be interpreted carefully. In the
intermediate threshold regime, the numerical experiments support the required
PCL conditions but do not prove them. Consequently, global indexability and
global identification of the MP index with the Whittle index remain
conjectural in that regime. Likewise, the threshold-dual/Lagrangian benchmark
stored in the policy data is conditional rather than a globally certified
upper bound.

## Contents

- `Project.toml`, `Manifest.toml` — canonical Julia environment.
- `reproducibility/src/` — primary Julia modules used in the recent revision.
- `reproducibility/notebooks/` — current v4 notebook.
- `reproducibility/provenance/mac_legacy/` — older MacBook notebook and source
  associated with the broad PCLI experiments.
- `reproducibility/data/raw/` — immutable final raw outputs.
- `reproducibility/data/processed/` — canonical, analysis-ready tables.
- `reproducibility/data/checks/` — machine-readable validation results.
- `reproducibility/figures/manuscript/` — August release figures.
- [Submitted figures](reproducibility/figures/submitted/) — the four main figures and twelve supplementary figures in the submitted revision. The CSV identifies each figure, page, filename, and SHA-256.
- `reproducibility/provenance/` — hashes, environment capture, import records,
  and curation manifests.
- `scripts/` — release validation and deterministic curation utilities.
- `docs/` — reproduction guide, data dictionary, environment notes, licensing,
  release scope, and Zenodo checklist.

## Quick validation

Install Julia 1.12.x, clone the repository, and instantiate the pinned project:

```bash
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

Then run the release-level validator:

```bash
python scripts/validate_release.py
```

The validator checks the archived result checks, processed-data hashes,
environment capture, canonical figure hashes, licensing metadata, and required
release files. It does not rerun the large simulations or broad PCLI grids.

To rebuild the processed tables from the archived raw data:

```bash
julia --project=. scripts/curate_existing_results.jl .
```

For fuller instructions, see `docs/REPRODUCTION_GUIDE.md`.

## Principal archived experiments

- Broad PCLI1 grid: 30,184 parameter tuples and 59 checkpoint chunks.
- Broad PCLI2 grid: 30,184 parameter tuples and 59 checkpoint chunks.
- Boundary-focused PCLI stress test: 320 coarse tuples plus refinements.
- Heterogeneous four-policy comparison: 4,320 instances and 17,280 policy rows.
- Homogeneous-project tie diagnostic: 168 cases and 672 policy rows.
- Representative policy experiment: 10,000 paired replications.
- Canonical manuscript figures: 16 PDFs.

The release-level result curation passed 162 out of 162 checks.

## Terminology in legacy raw files

The imported broad-PCLI raw files use the historical column name `q` for the
transition probability denoted by `p01` or \(p_{01}\) in the revised paper.
Those raw files are preserved byte-for-byte. The processed files rename the
columns to `p01`, `rho`, `kappa`, and `beta`.

## Citation

Citation metadata are provided in `CITATION.cff`. The Zenodo DOI for release
`v1.0.0` will be added to the manuscript after the GitHub release has been
archived.

## Licensing

This is a mixed-license repository:

- source code, scripts, and executable notebook code: **MIT License**;
- data, static figures, prose documentation, and non-code notebook content:
  **Creative Commons Attribution 4.0 International**.

See `LICENSE`, `LICENSE-DATA`, and `LICENSES.md` for precise scope.
