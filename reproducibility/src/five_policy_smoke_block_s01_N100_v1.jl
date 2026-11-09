using Random
using Statistics
using Distributions
using DataFrames
using CSV

using .FivePolicyRunnerRkappa:
    FIVE_POLICY_ORDER,
    run_five_policy_pilot


"""
Run the checkpointed five-policy N=100 smoke block.

Keeping the executable block inside a function is intentional: this file is
normally included from a Jupyter notebook, where top-level `for` loops use
Julia's soft-scope rules.  Local function scope prevents existing notebook
globals such as `M` and `smoke_grid` from shadowing loop assignments.
"""
function run_five_policy_smoke_block_s01_N100()

# -------------------------------------------------------------------------
# Five-policy grid smoke block
# Scenario 1, all 9 compositions x 8 capacities, N=100
# -------------------------------------------------------------------------

smoke_scenario_index = 1
smoke_scenario_name = "A_very_selfhealing_B_fragile"
smoke_types = benchmark_diagnostic.types
smoke_labels = benchmark_diagnostic.labels

prop_A_values = collect(0.1:0.1:0.9)
alphaM_values = [
    0.05,
    0.10,
    0.15,
    0.20,
    0.25,
    0.30,
    0.40,
    0.50
]

N_smoke = 100
T_grid = 700
nruns_grid = 1_000
base_seed_grid = 20260810

output_file = "five_policy_grid_s01_N100_T700_n1000_v1.csv"

# Resume safely if this block was interrupted earlier.
if isfile(output_file)
    smoke_grid = CSV.read(output_file, DataFrame)
else
    smoke_grid = DataFrame()
end

expected_policies = Set(string.(collect(FIVE_POLICY_ORDER)))
completed_case_ids = Set{Int}()

if nrow(smoke_grid) > 0
    for group in groupby(smoke_grid, :case_id)
        if nrow(group) != 5 ||
           Set(String.(group.policy)) != expected_policies
            error(
                "The existing checkpoint contains an incomplete case: " *
                "case_id=$(first(group.case_id))."
            )
        end

        push!(completed_case_ids, first(group.case_id))
    end
end

# Scenario 1 is the representative scenario, so these validated tables can
# be reused. They do not depend on p_A, M, or N.
mp_tables_smoke = seven_policy_pilot.mp_tables
lwz_tables_smoke = benchmark_diagnostic.lwz_tables

block_start = time()
new_cases = 0

for (p_index, p_A) in enumerate(prop_A_values)
    for (alpha_index, alphaM) in enumerate(alphaM_values)

        # This is the case number in the future 4,320-instance grid.
        # The final +1 selects N=100, the first entry in the size grid.
        case_id =
            (((smoke_scenario_index - 1) * 9 +
              (p_index - 1)) * 8 +
              (alpha_index - 1)) * 5 + 1

        case_id in completed_case_ids && continue

        M = round(Int, alphaM * N_smoke)
        n_A = round(Int, p_A * N_smoke)

        type_of_plan = vcat(
            fill(1, n_A),
            fill(2, N_smoke - n_A)
        )

        initial_beliefs = fill(0.5, N_smoke)

        # Shuffle type labels for the simulation so deterministic project-label
        # tie-breaking is not systematically associated with either type.
        instance_seed = base_seed_grid + case_id
        type_of_simulation = copy(type_of_plan)
        shuffle!(
            MersenneTwister(instance_seed + 50_000_000),
            type_of_simulation
        )

        setup_start = time()

        plan = solve_lagrangian_plan(
            initial_beliefs,
            type_of_plan,
            smoke_types,
            M,
            pcl_callbacks;
            lambda_tol=1e-8,
            subgradient_tol=1e-10,
            max_bisect_iter=100,
            value_is_certified=false
        )

        lagrangian_tables = build_lagrangian_tables(
            plan,
            pcl_callbacks;
            nx=4001,
            labels=smoke_labels
        )

        plan_table_seconds = time() - setup_start

        result = run_five_policy_pilot(
            initial_beliefs,
            type_of_simulation,
            smoke_types,
            M;
            mp_tables=mp_tables_smoke,
            lwz_tables=lwz_tables_smoke,
            lagrangian_tables=lagrangian_tables,
            T=T_grid,
            nruns=nruns_grid,
            seed=instance_seed,
            threaded=true,
            verify_reproducibility=false
        )

        result.all_rewards_finite ||
            error("Nonfinite reward in case $case_id.")

        result.all_priorities_finite ||
            error("Nonfinite priority in case $case_id.")

        capacity_ok = true

        for j in eachindex(result.policies)
            capacity_row = result.capacity[j]

            if result.policies[j] == :lagrangian
                capacity_ok &=
                    0 <= capacity_row.min_active <=
                    capacity_row.max_active <= M
            else
                capacity_ok &=
                    capacity_row.min_active == M &&
                    capacity_row.max_active == M
            end
        end

        capacity_ok ||
            error("Capacity validation failed in case $case_id.")

        mp_column = findfirst(==(:mp_index), result.policies)
        mp_mean = result.summary[mp_column].mean
        tcrit = quantile(TDist(result.nruns - 1), 0.975)

        conditional_bound = plan.normalized_value

        tail_upper =
            result.beta_tail *
            (M / N_smoke) *
            maximum(project_type.r for project_type in smoke_types)

        case_rows = NamedTuple[]

        for j in eachindex(result.policies)
            policy = result.policies[j]
            summary_row = result.summary[j]
            capacity_row = result.capacity[j]

            mean_reward = summary_row.mean
            standard_error = summary_row.stderr
            ci_low = mean_reward - tcrit * standard_error
            ci_high = mean_reward + tcrit * standard_error

            if j == mp_column
                paired_mean = missing
                paired_stderr = missing
                paired_ci_low = missing
                paired_ci_high = missing
                paired_pvalue = missing
                relative_difference_vs_mp = missing
            else
                differences =
                    result.normalized_rewards[:, j] .-
                    result.normalized_rewards[:, mp_column]

                paired_mean = mean(differences)
                paired_stderr = std(differences) / sqrt(result.nruns)
                paired_ci_low = paired_mean - tcrit * paired_stderr
                paired_ci_high = paired_mean + tcrit * paired_stderr

                if paired_stderr == 0.0
                    paired_pvalue = paired_mean == 0.0 ? 1.0 : 0.0
                else
                    tstat = paired_mean / paired_stderr
                    paired_pvalue =
                        2 * ccdf(
                            TDist(result.nruns - 1),
                            abs(tstat)
                        )
                end

                relative_difference_vs_mp = paired_mean / mp_mean
            end

            upper_95_with_tail = ci_high + tail_upper

            push!(
                case_rows,
                (
                    case_id=case_id,
                    scenario_index=smoke_scenario_index,
                    scenario=smoke_scenario_name,
                    prop_index=p_index,
                    p_A=p_A,
                    p_B=1.0 - p_A,
                    alpha_index=alpha_index,
                    alphaM_target=alphaM,
                    N=N_smoke,
                    M=M,
                    capacity_ratio=M / N_smoke,
                    T=result.T,
                    nruns=result.nruns,
                    beta=result.beta,
                    beta_tail=result.beta_tail,
                    seed=instance_seed,

                    policy=String(policy),
                    label=summary_row.label,
                    mean_reward=mean_reward,
                    stderr=standard_error,
                    ci_low=ci_low,
                    ci_high=ci_high,

                    paired_mean_vs_mp=paired_mean,
                    paired_stderr_vs_mp=paired_stderr,
                    paired_ci_low_vs_mp=paired_ci_low,
                    paired_ci_high_vs_mp=paired_ci_high,
                    paired_pvalue_vs_mp=paired_pvalue,
                    relative_difference_vs_mp=
                        relative_difference_vs_mp,

                    min_active=capacity_row.min_active,
                    max_active=capacity_row.max_active,
                    mean_active=capacity_row.mean_active,
                    idle_slots=capacity_row.idle_slots,
                    idle_slot_fraction=
                        capacity_row.idle_slot_fraction,

                    lambda_star=plan.lambda_star,
                    conditional_lagrangian_bound=conditional_bound,
                    bound_value_is_certified=plan.value_is_certified,
                    bound_status=
                        "conditional on global PCL-indexability",
                    zstar_type_A=plan.zstars[1],
                    zstar_type_B=plan.zstars[2],
                    lambda_bracket_width=
                        plan.lambda_hi - plan.lambda_lo,
                    bound_iterations=plan.iterations,

                    point_gap_to_bound=
                        conditional_bound - mean_reward,
                    relative_point_gap_to_bound=
                        (conditional_bound - mean_reward) /
                        conditional_bound,
                    normalized_tail_upper_bound=tail_upper,
                    upper_95_with_tail=upper_95_with_tail,
                    conservative_gap_to_bound=
                        conditional_bound - upper_95_with_tail,

                    plan_table_seconds=plan_table_seconds,
                    simulation_seconds=result.elapsed_seconds,
                    seconds_per_replication=
                        result.seconds_per_replication,
                    lwz_fallback_count=result.lwz_fallback_count,
                    all_rewards_finite=result.all_rewards_finite,
                    all_priorities_finite=
                        result.all_priorities_finite,
                    forced_capacity_ok=capacity_ok
                )
            )
        end

        case_df = DataFrame(case_rows)

        if nrow(smoke_grid) == 0
            smoke_grid = case_df
        else
            smoke_grid = vcat(smoke_grid, case_df; cols=:union)
        end

        sort!(smoke_grid, [:case_id, :policy])

        # Atomic checkpoint after every completed instance.
        temporary_file = output_file * ".tmp"
        CSV.write(temporary_file, smoke_grid)
        mv(temporary_file, output_file; force=true)

        push!(completed_case_ids, case_id)
        new_cases += 1

        println(
            "[$(length(completed_case_ids))/72] ",
            "p_A=$(p_A), alpha=$(alphaM), M=$(M), ",
            "setup=$(round(plan_table_seconds; digits=2)) s, ",
            "simulation=$(round(result.elapsed_seconds; digits=2)) s, ",
            "elapsed=$(round((time() - block_start) / 60; digits=1)) min"
        )
    end
end

instance_timings = unique(
    select(
        smoke_grid,
        :case_id,
        :plan_table_seconds,
        :simulation_seconds
    )
)

unique_fallback_counts = unique(
    select(
        smoke_grid,
        :case_id,
        :lwz_fallback_count
    )
)

smoke_check = DataFrame([(
    completed_instances=nrow(instance_timings),
    expected_instances=72,
    policy_rows=nrow(smoke_grid),
    expected_policy_rows=72 * 5,
    new_instances_this_run=new_cases,
    total_plan_table_seconds=
        sum(instance_timings.plan_table_seconds),
    total_simulation_seconds=
        sum(instance_timings.simulation_seconds),
    wall_minutes_this_run=(time() - block_start) / 60,
    all_rewards_finite=all(smoke_grid.all_rewards_finite),
    all_priorities_finite=all(smoke_grid.all_priorities_finite),
    forced_capacity_ok=all(smoke_grid.forced_capacity_ok),
    total_lwz_fallback_count=
        sum(unique_fallback_counts.lwz_fallback_count),
    minimum_conservative_gap_to_conditional_bound=
        minimum(smoke_grid.conservative_gap_to_bound)
)])

@show abspath(output_file)
display(smoke_check)

return (
    smoke_grid=smoke_grid,
    smoke_check=smoke_check,
    output_file=output_file
)
end


# Preserve the notebook-facing names used in the original workflow.
five_policy_smoke_block = run_five_policy_smoke_block_s01_N100()
smoke_grid = five_policy_smoke_block.smoke_grid
smoke_check = five_policy_smoke_block.smoke_check
output_file = five_policy_smoke_block.output_file
