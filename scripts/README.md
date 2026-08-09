# Scripts

- `validate_release.py` — read-only validation of archived data, hashes,
  figures, environment capture, licensing, and metadata; writes deterministic
  release-validation reports.
- `curate_existing_results.jl` — rebuilds processed tables and the 162
  experiment checks from immutable raw outputs; does not rerun simulations.
- `windows/curate_figures.ps1` — reconstructs the canonical figure directory
  from validated PDFs and two recovered standalone PGFPlots sources.
- `provenance/capture_environment.jl` — records the active Julia environment
  without changing it.

The full numerical experiments are launched from the notebooks and checkpointed
modules described in `docs/REPRODUCTION_GUIDE.md`.
