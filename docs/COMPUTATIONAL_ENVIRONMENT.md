# Computational environment

## Canonical supported environment

The repository-root `Project.toml` and `Manifest.toml` define the supported
Julia environment.

Captured configuration for the recent revision workflow:

- Julia 1.12.6.
- Windows x86-64.
- Intel Core i7-8700.
- 12 Julia threads.
- 6 BLAS threads.
- Approximately 16 GB RAM.

Direct Julia dependencies:

| Package | Version |
|---|---:|
| CSV | 0.10.16 |
| DataFrames | 1.8.2 |
| Distributions | 0.25.130 |
| IJulia | 1.34.4 |
| LaTeXStrings | 1.4.0 |
| PGFPlotsX | 1.6.2 |
| StatsBase | 0.34.12 |

The full dependency graph and exact versions are pinned in `Manifest.toml`.
The captured project and manifest are duplicated under
`reproducibility/provenance/julia_environment_used/` and verified by SHA-256.

## Threading

The current v4 notebook was run with 12 Julia threads and 6 BLAS threads.
The deterministic data-curation pass was launched in a one-thread Julia
process; this is immaterial because it only read, sorted, checked, and wrote
existing CSVs. It did not perform simulations or metric-grid calculations.

For full reruns, launch Julia with an explicit thread count, for example:

```bash
julia --threads=auto --project=.
```

The broad tuple scans parallelize across parameter tuples and set BLAS to one
thread internally to avoid nested parallelism.

## Figure toolchain

The two recovered standalone PGFPlots sources were compiled with MiKTeX
`pdflatex`. The canonical PDF directory contains the compiled results and a
file-level manifest. A TeX installation is needed only to rebuild those PDFs,
not to validate the numerical data.

## Legacy broad-PCLI environment

The original MacBook directory for the broad PCLI1 and PCLI2 computations did
not contain a `Project.toml` or `Manifest.toml`. The release therefore preserves:

- the original notebook and supporting source;
- all 59 checkpoint chunks for each broad experiment;
- complete final aggregate files;
- file-level SHA-256 import records;
- deterministic processed copies under the current naming convention.

The repository-root Julia project is the supported environment for current
inspection, validation, and future reruns.
