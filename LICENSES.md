# Licensing

This repository contains software, data, figures, notebooks, and
documentation. The licenses apply by file type and function as follows.

## MIT License

The MIT License in the root `LICENSE` file applies to:

- Julia source files under `reproducibility/src/`;
- scripts under `scripts/`;
- executable code cells in the Jupyter notebooks;
- small code fragments in the documentation that are intended to be run.

Copyright © 2026 José Niño-Mora.

## Creative Commons Attribution 4.0 International

The CC BY 4.0 license in `LICENSE-DATA` applies to:

- CSV data under `reproducibility/data/`;
- static figures and their non-software source material under
  `reproducibility/figures/`;
- prose documentation under `docs/` and `reproducibility/README.md`;
- markdown cells, explanatory prose, and stored outputs in notebooks;
- machine-readable validation reports and provenance records, except for
  embedded source code, which remains under the MIT License.

A suitable attribution is:

> José Niño-Mora (2026), *Code and data for “Restless bandits with imperfect
> binary feedback: PCL-indexability analysis and computation”*, version 1.0.0,
> GitHub/Zenodo.

When reusing modified data or figures, indicate that changes were made.

## Third-party material

Third-party Julia packages and system tools retain their own licenses. Their
inclusion in `Manifest.toml` or mention in the documentation does not relicense
them. The associated journal manuscript is not itself distributed under these
repository licenses unless a copy is explicitly included with a separate
license notice.

## Zenodo record

The Zenodo deposit should declare both licenses because the archive contains
materials under different licenses:

- `MIT`
- `CC-BY-4.0`
