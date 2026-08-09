# GitHub–Zenodo release checklist

This repository intentionally uses `CITATION.cff` and does not include a
`.zenodo.json` file. This allows GitHub to display citation metadata and lets
Zenodo read the same open metadata file.

## Before creating the release

1. Run:

   ```bash
   python scripts/validate_release.py
   ```

2. Confirm that every validation row is `PASS`.
3. Inspect `git status` and ensure that local staging/audit files are ignored.
4. Commit and push the curated release tree.
5. Test from a fresh clone:
   - instantiate the Julia project;
   - run `scripts/validate_release.py`;
   - optionally rerun `scripts/curate_existing_results.jl`.

## Zenodo setup

1. Sign in to Zenodo and enable the GitHub repository
   `jnimora/paperPCLsensingErrors`.
2. Create GitHub release `v1.0.0`.
3. Wait for Zenodo to ingest the release.
4. Review the Zenodo draft/record metadata:
   - resource type: Software;
   - title from `CITATION.cff`;
   - creator: José Niño-Mora;
   - ORCID: 0000-0002-2172-3983;
   - affiliation: Universidad Carlos III de Madrid;
   - version: 1.0.0;
   - access: public/open.
5. Because this is a mixed-license archive, add both:
   - MIT License;
   - Creative Commons Attribution 4.0 International.
6. Verify the description and keywords.
7. Publish the record.

## After publication

1. Record the version DOI for `v1.0.0`.
2. Record the concept DOI for the repository as a whole.
3. Insert the version DOI in the revised manuscript’s code-and-data
   availability statement.
4. Add the DOI badge and DOI to the repository README in a subsequent commit.
5. Preserve the `v1.0.0` tag; do not rewrite it.
6. For later changes, create a new release rather than replacing the archived
   files.

## Suggested manuscript statement

```latex
\section*{{Code and data availability}}

The Julia source code, experiment specifications, random-seed information,
numerical datasets, validation records, and figure-generation materials
supporting this article are archived in Zenodo at DOI:
\texttt{{10.5281/zenodo.XXXXXXXX}}. The archive corresponds to release
\texttt{{v1.0.0}} of the associated GitHub repository.
```

Replace the placeholder with the version-specific Zenodo DOI.
