# Public release scope

## Included

The public GitHub/Zenodo release includes:

- the repository Julia project and manifest;
- primary recent-revision Julia modules;
- the current v4 notebook;
- the legacy notebook/source needed to interpret the broad PCLI runs;
- final raw, processed, and supporting data;
- all machine-readable experiment checks;
- canonical manuscript figures and selected figure sources;
- environment capture, import validation, and curation manifests;
- release documentation, licensing, and validation scripts.

## Retained locally but excluded

The following are deliberately excluded from the public release because they
are staging artifacts, duplicate checkpoints, or superseded pilot material:

- `clean_benchmark_v4/`, which remains the untouched office-PC working folder;
- initial staging and recovery audit directories;
- the first-stage `STAGING_NOTES.md`;
- the complete working-folder inventory and freeze manifests;
- superseded five-policy and homogeneous-tie-v1 pilot files;
- duplicate `.ipynb_checkpoints`;
- temporary LaTeX console logs and temporary files.

The exclusion rules are recorded in `.gitignore`. No final raw dataset or
canonical figure is excluded.
