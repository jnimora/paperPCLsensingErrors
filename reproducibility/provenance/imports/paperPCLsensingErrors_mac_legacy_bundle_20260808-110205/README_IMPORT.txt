paperPCLsensingErrors legacy MacBook transfer bundle
Generated: 2026-08-08T11:02:06.115811+01:00

Source directory:
    /Users/josenino-mora/Documents/Docum2/work/Research/Labs/juliaLab/Projects/sensingErrors

This bundle was created by copying only. No source file was modified,
moved, renamed, deleted, staged, committed, or pushed.

Validated complete broad experiments:
- PCLI1: serious_run_14x14x14x11_121x121_eps1e8
  - 59 checkpoint chunks
  - 30,184 total chunk rows
  - all_results_sorted.csv: 30,184 rows
  - worst_200.csv: 200 rows

- PCLI2: serious_run_pcli2_14x14x14x11_uniformx_Nmid2001_Nside201
  - 59 checkpoint chunks
  - 30,184 total chunk rows
  - three full 30,184-row sorted result files
  - three corresponding 200-row worst-case files

The legacy result CSVs use the historical column name q for p01.
They should be preserved unchanged as raw data. A curated processed layer
may rename q to p01 while documenting the transformation.

The files mp_index_vs_rho.tex and mp_family_q.tex contain the PGFPlots
coordinate data needed to recover the two missing PDFs. For the release,
mp_family_q should be documented or regenerated under the clearer name
mp_family_p01.

This transfer bundle is not itself the final GitHub/Zenodo layout. It is
an immutable import source for the curated reproducibility tree.
