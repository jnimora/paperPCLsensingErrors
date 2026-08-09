# Data dictionary

## Directory conventions

- `data/raw/`: immutable outputs produced by the original experiments.
- `data/processed/`: canonical tables produced deterministically from raw data.
- `data/supporting/`: smaller diagnostics and representative experiments.
- `data/checks/`: machine-readable validation results.

## Common model parameters

| Field | Meaning |
|---|---|
| `p01` | Transition probability from latent state 0 to state 1. |
| `q` | Historical raw-file name for `p01`; preserved only in legacy raw files. |
| `rho` or `ρ` | Autocorrelation/persistence parameter. |
| `kappa` or `κ` | ACK-given-good / feasible access parameter. |
| `beta` or `β` | Discount factor. |
| `r` or `reward` | Reward scale. |
| `x` | Belief that the latent state is good. |
| `z` | Threshold used by a threshold policy. |
| `x1`, `x0` | Fixed points delimiting the intermediate threshold regime. |

## Broad PCLI1 data

Raw directory:

```text
reproducibility/data/raw/pcli_broad/pcli1/
```

Principal files:

- `chunk_001.csv` through `chunk_059.csv`: checkpoint chunks.
- `all_results_sorted.csv`: all 30,184 tuples, sorted by minimum slack.
- `worst_200.csv`: first 200 rows of the sorted aggregate.
- parameter-grid CSVs and `run_info.txt`.

Key columns:

| Field | Meaning |
|---|---|
| `q` | Historical name for `p01`. |
| `ρ`, `κ`, `β` | Model parameters. |
| `x0`, `x1` | Threshold-regime fixed points. |
| `min_slack` | Minimum sampled value of `g(x,z) - (1-beta)`. |
| `rel_slack` | `min_slack / (1-beta)`. |
| `xstar`, `zstar` | Grid point at which the minimum was attained. |

Canonical processed file:

```text
reproducibility/data/processed/pcli1_broad_all_results_p01.csv
```

It contains the same rows with ASCII parameter names `p01`, `rho`, `kappa`,
and `beta`.

## Broad PCLI2 data

Raw directory:

```text
reproducibility/data/raw/pcli_broad/pcli2/
```

Principal files:

- 59 checkpoint chunks.
- `all_results_sorted_by_min_diff_all.csv`.
- `all_results_sorted_by_min_diff_core.csv`.
- `all_results_sorted_by_endpoint_cont_proxy_desc.csv`.
- three corresponding `worst_200_*.csv` files.

The three full raw aggregates contain the same 30,184 rows in different
orders.

Key columns:

| Field | Meaning |
|---|---|
| `min_g_diag` | Minimum sampled diagonal marginal work. |
| `min_diff_all` | Minimum adjacent MP-index difference on the padded interval. |
| `min_diff_core` | Minimum adjacent MP-index difference on `[x1,x0]`. |
| `endpoint_cont_proxy` | Largest of four endpoint-adjacent absolute differences. |
| `mono_pass_all` | Numerical monotonicity flag on the padded interval. |
| `mono_pass_core` | Numerical monotonicity flag on the core interval. |
| `mono_pass_endpoints` | Endpoint-adjacent monotonicity flag. |
| `n_nonfinite_*` | Counts of nonfinite sampled metric values. |
| `n_nonpositive_g` | Count of nonpositive sampled marginal-work values. |

Canonical processed file:

```text
reproducibility/data/processed/pcli2_broad_all_results_p01.csv
```

## Boundary-focused PCLI stress test

Raw directory:

```text
reproducibility/data/raw/pcli_boundary_stress/
```

Files:

- `pcli_boundary_stress_v1_coarse.csv`: 320 coarse tuples.
- `pcli_boundary_stress_v1_refined_pcli1.csv`: 20 PCLI1 refinements.
- `pcli_boundary_stress_v1_refined_pcli2.csv`: 20 PCLI2 refinements.
- `pcli_boundary_stress_v1_quantiles.csv`: empirical quantiles.
- `pcli_boundary_stress_v1_near_tolerance_counts.csv`: near-tolerance counts.
- `pcli_boundary_stress_v1_check.csv`: completion and sign checks.

The PCLI2 stress-test outputs use secant slopes, i.e. index differences divided
by belief-grid spacing.

## Four-policy heterogeneous experiment

Raw directory:

```text
reproducibility/data/raw/four_policy_grid/
```

There are 12 scenario files. Their canonical concatenation is:

```text
reproducibility/data/processed/four_policy_grid_all_T700_n1000_v1.csv
```

Dimensions:

- 4,320 cases.
- 17,280 policy rows.
- four rows per case.

Key columns:

| Field | Meaning |
|---|---|
| `case_id` | Unique case identifier, 1 through 4,320. |
| `scenario_index`, `scenario` | Heterogeneity scenario. |
| `N`, `M` | Number of projects and activation capacity. |
| `T`, `nruns` | Horizon and replication count. |
| `seed` | Simulation seed. |
| `policy` | `mp_index`, `myopic`, `lwz4`, or `lagrangian_forced`. |
| `mean_reward`, `stderr` | Estimated normalized reward and standard error. |
| `conditional_lagrangian_bound` | Threshold-dual benchmark value. |
| `bound_value_is_certified` | False in this release. |
| `bound_status` | Explicit conditional-status text. |
| `conservative_gap_to_bound` | Conservative reported difference to benchmark. |
| `exact_capacity_ok` | Whether the policy used exactly the required capacity. |

## Homogeneous tie diagnostic

Raw and processed file:

```text
homogeneous_tie_grid_T700_n1000_v2.csv
```

Dimensions:

- 168 cases.
- 672 rows.
- four policy/tie-rule rows per case.

Key fields include `profile`, `alphaM_target`, `N`, `M`, `policy`,
`mean_reward`, MP-table sign/monotonicity flags, action-mismatch counts, and
exact reward-equality flags.

## Representative and supporting policy data

Directory:

```text
reproducibility/data/supporting/pilot_diagnostics/
```

Important files:

- `representative_T700_n10000_rewards_v1.csv`: replication-level rewards.
- `representative_T700_n10000_report_v1.csv`: policy summaries and intervals.
- `representative_T700_n10000_top3_pairwise_v1.csv`: paired comparisons.
- `representative_T700_n10000_capacity_v1.csv`: capacity diagnostics.
- `representative_T700_n10000_metadata_v1.csv`: design and runtime metadata.
- `seven_policy_horizon_sensitivity_v1.csv`: horizon sensitivity.
- `seven_policy_scaling_timing_T700_n100_v1.csv`: timing diagnostics.

## Checks

`all_experiment_checks_v1.csv` contains one row per validation assertion:

- `dataset`
- `check`
- `status`
- `value`
- `expected`
- `note`

The release contains 162 checks, all with status `PASS`.
