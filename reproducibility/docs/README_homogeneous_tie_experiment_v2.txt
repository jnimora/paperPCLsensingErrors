CORRECTED HOMOGENEOUS-PROJECT TIE DIAGNOSTIC (V2)

Purpose
-------
Quantify how often ties occur in homogeneous projects, verify directly that
MP and myopic/belief ranking coincide after resolving numerical MP-priority
collisions by belief, and assess sensitivity to fixed, cyclic, and randomized
tie-breaking. The implemented MP rule ranks lexicographically by

   (tabulated MP priority, belief, fresh random tie key),

with the first two components in decreasing order. Thus belief is used only
when two numerical MP priorities are exactly equal, and randomization is used
only when the beliefs are also exactly equal.

Default full design
-------------------
- Seven homogeneous profiles: the four A and three B profiles in the paper.
- Capacity ratios: 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40, 0.50.
- N = 100, 400, 1600.
- T = 700, 1000 replications, beta = 0.99, x_initial = 0.5.
- 168 cases and four policy/tie-rule rows per case (672 CSV rows).
- Exact capacity M is used in every period.

Before running
--------------
Use the same Julia notebook/session in which the modules
SensingErrorBenchmarkIndices and SevenPolicyPilotRkappa and the exact MP-index
function used in the four-policy experiment are already defined.

1. Put homogeneous_tie_grid_lexicographic_random_v2.jl in that working
   directory. Keep the v1 CSV as an audit record; v2 writes a separate file.

2. In a new notebook cell, load the runner:

   include("homogeneous_tie_grid_lexicographic_random_v2.jl")
   import .HomogeneousTieGridRkappaV2

Full-scale one-case preflight
-----------------------------
The completed four-policy experiment used `mp_index_for_pilot`, so run:

   tie_preflight_v2 = HomogeneousTieGridRkappaV2.run_homogeneous_tie_grid(
       mp_index_fn=mp_index_for_pilot,
       max_new_cases=1,
       threaded=true
   )

The preflight deliberately uses T=700 and 1000 replications. It writes the
first completed case atomically to:

   homogeneous_tie_grid_T700_n1000_v2.csv

Before launching the rest, the displayed check should show:

- completed_instances_requested = 1;
- policy_rows = 4;
- all rewards and priorities finite;
- exact capacity satisfied;
- all tested MP tables nonnegative and nondecreasing;
- zero MP/randomized-myopic action-mismatch periods; and
- exact equality of MP and randomized-myopic replication rewards.

Full run
--------
After the preflight passes, rerun without max_new_cases:

   tie_full_v2 = HomogeneousTieGridRkappaV2.run_homogeneous_tie_grid(
       mp_index_fn=mp_index_for_pilot,
       threaded=true
   )

The runner resumes from the one-case v2 checkpoint. It does not repeat the
preflight case. If interrupted, execute the same call again to resume.

Final validation
----------------
When the run finishes:

   tie_validation_v2 = HomogeneousTieGridRkappaV2.validate_homogeneous_tie_output(
       "homogeneous_tie_grid_T700_n1000_v2.csv"
   )
   display(tie_validation_v2.audit)

The completed file should contain 168 cases and 672 rows. In particular, the
audit should report:

   total_mp_random_action_mismatch_periods = 0
   all_mp_random_rewards_exact = true

Important output measures
-------------------------
- cutoff_tie_fraction: periods in which a genuine equal-belief class straddles
  the Mth position, including the necessarily tied initial period;
- cutoff_tie_fraction_excluding_initial: the same measure from period 2 on;
- ambiguous_activation_fraction: fraction of activation decisions filled from
  a genuine tie class that straddles the cutoff;
- mean/max cutoff-class size;
- mean_activation_count_cv: label-level activation imbalance;
- paired reward differences from randomized belief/myopic ranking; and
- MP/randomized-myopic sample-path equivalence checks.

Why all 168 cases are rerun
---------------------------
The v1 diagnostic used fixed-label ties for MP. V2 adopts randomized genuine
ties as the actual MP rule and compares it sample-path by sample-path with
randomized belief ranking. Although only 14 v1 cases displayed numerical
MP/belief collisions, the tie-rule change affects the policy implementation in
all cases, so a separate complete v2 checkpoint is the cleanest audit.

Do not run the Lagrangian or LWZ4 policies in this experiment: they do not
answer the homogeneous tie-breaking question and would add avoidable runtime.
