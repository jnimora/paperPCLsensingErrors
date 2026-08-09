module FourPolicyFullGridRkappa

using Random
using Statistics
using Distributions
using DataFrames
using CSV

using ..SensingErrorBenchmarkIndices:
    BSFProjectType,
    solve_lagrangian_plan,
    build_lagrangian_tables,
    build_lwz_tables

using ..SevenPolicyPilotRkappa:
    build_mp_tables

using ..FourPolicyRunnerRkappa:
    FOUR_POLICY_ORDER,
    run_four_policy_pilot

export FOUR_POLICY_GRID_N_VALUES,
       four_policy_grid_scenarios,
       four_policy_grid_manifest,
       four_policy_grid_case_id,
       run_four_policy_grid_scenario,
       combine_four_policy_grid_outputs


const FOUR_POLICY_GRID_N_VALUES = [100, 200, 400, 800, 1600]
const _PROP_A_VALUES = collect(0.1:0.1:0.9)
const _ALPHAM_VALUES = [
    0.05,
    0.10,
    0.15,
    0.20,
    0.25,
    0.30,
    0.40,
    0.50
]

const _A_PROFILES = [
    (
        name="A_very_selfhealing",
        p01=0.01,
        rho=0.90,
        kappa=0.70,
        r=1.0
    ),
    (
        name="A_mild_selfhealing",
        p01=0.03,
        rho=0.80,
        kappa=0.70,
        r=1.0
    ),
    (
        name="A_balanced",
        p01=0.05,
        rho=0.70,
        kappa=0.70,
        r=1.0
    ),
    (
        name="A_harder_obs",
        p01=0.02,
        rho=0.85,
        kappa=0.55,
        r=1.0
    )
]

const _B_PROFILES = [
    (
        name="B_fragile",
        p01=0.10,
        rho=0.10,
        kappa=0.95,
        r=1.0
    ),
    (
        name="B_very_fragile",
        p01=0.15,
        rho=0.05,
        kappa=0.95,
        r=1.0
    ),
    (
        name="B_persistent_bad",
        p01=0.08,
        rho=0.20,
        kappa=0.95,
        r=1.0
    )
]

const _RUNNER_REVISION = "2026-08-03-four-policy-full-grid-v1"
const _BOUND_STATUS = "conditional on global PCL-indexability"


"""
Return the 12 parameter scenarios in the same order as the paper-grid cell.
The first coordinate (type A) varies fastest, matching `vec([A, B])` in Julia.
"""
function four_policy_grid_scenarios(; beta::Real=0.99)
    betaf = Float64(beta)

    return vec([
        (
            name="$(A.name)_$(B.name)",
            A=A,
            B=B,
            types=[
                BSFProjectType(
                    p01=A.p01,
                    rho=A.rho,
                    kappa=A.kappa,
                    r=A.r,
                    beta=betaf
                ),
                BSFProjectType(
                    p01=B.p01,
                    rho=B.rho,
                    kappa=B.kappa,
                    r=B.r,
                    beta=betaf
                )
            ],
            labels=["type A", "type B"]
        )
        for A in _A_PROFILES, B in _B_PROFILES
    ])
end


function four_policy_grid_manifest(; beta::Real=0.99)
    scenarios = four_policy_grid_scenarios(; beta=beta)

    return DataFrame([
        (
            scenario_index=index,
            scenario=scenario.name,
            p01_type_A=scenario.A.p01,
            rho_type_A=scenario.A.rho,
            kappa_type_A=scenario.A.kappa,
            reward_type_A=scenario.A.r,
            p01_type_B=scenario.B.p01,
            rho_type_B=scenario.B.rho,
            kappa_type_B=scenario.B.kappa,
            reward_type_B=scenario.B.r,
            beta=Float64(beta),
            cases_per_scenario=
                length(_PROP_A_VALUES) *
                length(_ALPHAM_VALUES) *
                length(FOUR_POLICY_GRID_N_VALUES)
        )
        for (index, scenario) in enumerate(scenarios)
    ])
end


function four_policy_grid_case_id(
    scenario_index::Integer,
    prop_index::Integer,
    alpha_index::Integer,
    N_index::Integer
)
    1 <= scenario_index <= 12 ||
        throw(ArgumentError("scenario_index must lie in 1:12."))
    1 <= prop_index <= length(_PROP_A_VALUES) ||
        throw(ArgumentError("prop_index is outside the paper grid."))
    1 <= alpha_index <= length(_ALPHAM_VALUES) ||
        throw(ArgumentError("alpha_index is outside the paper grid."))
    1 <= N_index <= length(FOUR_POLICY_GRID_N_VALUES) ||
        throw(ArgumentError("N_index is outside the paper grid."))

    return (
        (((Int(scenario_index) - 1) * length(_PROP_A_VALUES) +
          (Int(prop_index) - 1)) * length(_ALPHAM_VALUES) +
          (Int(alpha_index) - 1)) * length(FOUR_POLICY_GRID_N_VALUES) +
        Int(N_index)
    )
end


function _scenario_tag(scenario_index::Integer)
    return "s" * lpad(string(Int(scenario_index)), 2, '0')
end


function _default_output_file(
    scenario_index::Integer,
    T::Integer,
    nruns::Integer
)
    return (
        "four_policy_grid_$(_scenario_tag(scenario_index))_" *
        "T$(Int(T))_n$(Int(nruns))_v1.csv"
    )
end


function _default_legacy_smoke_file(T::Integer, nruns::Integer)
    return (
        "five_policy_grid_s01_N100_" *
        "T$(Int(T))_n$(Int(nruns))_v1.csv"
    )
end


function _grid_N_index(N::Integer)
    index = findfirst(==(Int(N)), FOUR_POLICY_GRID_N_VALUES)
    index === nothing &&
        throw(ArgumentError("N=$(Int(N)) is outside the paper grid."))
    return index
end


function _atomic_csv_write(path::AbstractString, data::DataFrame)
    temporary_file = String(path) * ".tmp"
    CSV.write(temporary_file, data)
    mv(temporary_file, path; force=true)
    return path
end


function _add_or_validate_constant_column!(
    data::DataFrame,
    column::Symbol,
    value
)
    if column in propertynames(data)
        for observed in data[!, column]
            if ismissing(observed) || observed != value
                error(
                    "Checkpoint column $column is inconsistent with " *
                    "the requested scenario: observed=$observed, expected=$value."
                )
            end
        end
    else
        data[!, column] = fill(value, nrow(data))
    end

    return data
end


function _enrich_checkpoint!(
    data::DataFrame,
    scenario_index::Integer,
    scenario;
    x_initial::Real,
    table_nx::Integer,
    lwz_iterations::Integer,
    lwz_fallback::Symbol
)
    nrow(data) == 0 && return data

    if :N_index in propertynames(data)
        for row in eachrow(data)
            expected_N_index = findfirst(==(Int(row.N)), FOUR_POLICY_GRID_N_VALUES)
            expected_N_index === nothing &&
                error("Checkpoint contains an unsupported N=$(row.N).")
            Int(row.N_index) == expected_N_index ||
                error("Checkpoint N_index is inconsistent with N=$(row.N).")
        end
    else
        data[!, :N_index] = [
            _grid_N_index(Int(N))
            for N in data.N
        ]
    end

    constants = (
        runner_revision=_RUNNER_REVISION,
        x_initial=Float64(x_initial),
        table_nx=Int(table_nx),
        lwz_iterations=Int(lwz_iterations),
        lwz_fallback=String(lwz_fallback),
        p01_type_A=scenario.A.p01,
        rho_type_A=scenario.A.rho,
        kappa_type_A=scenario.A.kappa,
        reward_type_A=scenario.A.r,
        p01_type_B=scenario.B.p01,
        rho_type_B=scenario.B.rho,
        kappa_type_B=scenario.B.kappa,
        reward_type_B=scenario.B.r
    )

    for (column, value) in pairs(constants)
        _add_or_validate_constant_column!(data, column, value)
    end

    return data
end


function _expected_case_ids(scenario_index::Integer)
    return Set(
        four_policy_grid_case_id(
            scenario_index,
            prop_index,
            alpha_index,
            N_index
        )
        for prop_index in eachindex(_PROP_A_VALUES),
            alpha_index in eachindex(_ALPHAM_VALUES),
            N_index in eachindex(FOUR_POLICY_GRID_N_VALUES)
    )
end


function _validate_checkpoint(
    data::DataFrame,
    scenario_index::Integer,
    scenario;
    T::Integer,
    nruns::Integer,
    beta::Real,
    base_seed::Integer=20260810
)
    nrow(data) == 0 && return Set{Int}()

    required_columns = Set([
        :case_id,
        :scenario_index,
        :scenario,
        :prop_index,
        :p_A,
        :alpha_index,
        :alphaM_target,
        :N,
        :N_index,
        :M,
        :T,
        :nruns,
        :beta,
        :policy,
        :mean_reward,
        :conditional_lagrangian_bound,
        :bound_value_is_certified,
        :bound_status,
        :conservative_gap_to_bound,
        :all_rewards_finite,
        :all_priorities_finite,
        :exact_capacity_ok
    ])

    missing_columns = setdiff(required_columns, Set(propertynames(data)))
    isempty(missing_columns) ||
        error("Checkpoint is missing columns: $(collect(missing_columns)).")

    expected_policies = Set(string.(collect(FOUR_POLICY_ORDER)))
    expected_ids = _expected_case_ids(scenario_index)
    completed_case_ids = Set{Int}()

    for group in groupby(data, :case_id)
        case_id = Int(first(group.case_id))

        case_id in expected_ids ||
            error("Checkpoint has out-of-scenario case_id=$case_id.")

        nrow(group) == length(FOUR_POLICY_ORDER) ||
            error("Checkpoint has an incomplete case_id=$case_id.")

        Set(String.(group.policy)) == expected_policies ||
            error("Checkpoint has the wrong policies for case_id=$case_id.")

        nrow(unique(select(group, :policy))) == length(FOUR_POLICY_ORDER) ||
            error("Checkpoint duplicates a policy for case_id=$case_id.")

        for column in (
            :scenario_index,
            :scenario,
            :prop_index,
            :p_A,
            :alpha_index,
            :alphaM_target,
            :N,
            :N_index,
            :M,
            :T,
            :nruns,
            :beta,
            :seed,
            :lambda_star,
            :conditional_lagrangian_bound,
            :zstar_type_A,
            :zstar_type_B,
            :plan_table_seconds,
            :simulation_seconds
        )
            length(unique(group[!, column])) == 1 ||
                error(
                    "Checkpoint column $column varies within case_id=$case_id."
                )
        end

        first(group.scenario_index) == scenario_index ||
            error("Checkpoint scenario index does not match its file.")

        String(first(group.scenario)) == scenario.name ||
            error("Checkpoint scenario name does not match its index.")

        Int(first(group.T)) == Int(T) ||
            error("Checkpoint T does not match requested T=$(Int(T)).")

        Int(first(group.nruns)) == Int(nruns) ||
            error(
                "Checkpoint nruns does not match requested nruns=$(Int(nruns))."
            )

        isapprox(Float64(first(group.beta)), Float64(beta); atol=0.0, rtol=1e-14) ||
            error("Checkpoint beta does not match requested beta=$beta.")

        prop_index = Int(first(group.prop_index))
        alpha_index = Int(first(group.alpha_index))
        N_index = Int(first(group.N_index))

        expected_id = four_policy_grid_case_id(
            scenario_index,
            prop_index,
            alpha_index,
            N_index
        )

        case_id == expected_id ||
            error("Checkpoint case numbering is inconsistent at case_id=$case_id.")

        expected_N = FOUR_POLICY_GRID_N_VALUES[N_index]
        Int(first(group.N)) == expected_N ||
            error("Checkpoint N and N_index disagree at case_id=$case_id.")

        expected_p_A = _PROP_A_VALUES[prop_index]
        isapprox(
            Float64(first(group.p_A)),
            expected_p_A;
            atol=1e-14,
            rtol=0.0
        ) || error("Checkpoint p_A is inconsistent at case_id=$case_id.")

        expected_alphaM = _ALPHAM_VALUES[alpha_index]
        isapprox(
            Float64(first(group.alphaM_target)),
            expected_alphaM;
            atol=1e-14,
            rtol=0.0
        ) || error(
            "Checkpoint alphaM_target is inconsistent at case_id=$case_id."
        )

        expected_M = round(Int, expected_alphaM * expected_N)
        Int(first(group.M)) == expected_M ||
            error("Checkpoint M is inconsistent at case_id=$case_id.")

        Int(first(group.seed)) == Int(base_seed) + case_id ||
            error("Checkpoint seed is inconsistent at case_id=$case_id.")

        all(.!group.bound_value_is_certified) ||
            error(
                "Checkpoint incorrectly marks the conditional bound as " *
                "certified at case_id=$case_id."
            )

        all(String.(group.bound_status) .== _BOUND_STATUS) ||
            error("Checkpoint bound status is inconsistent at case_id=$case_id.")

        all(group.all_rewards_finite) ||
            error("Checkpoint records a nonfinite reward at case_id=$case_id.")

        all(group.all_priorities_finite) ||
            error("Checkpoint records a nonfinite priority at case_id=$case_id.")

        all(group.exact_capacity_ok) ||
            error("Checkpoint records a capacity failure at case_id=$case_id.")

        push!(completed_case_ids, case_id)
    end

    nrow(data) == length(completed_case_ids) * length(FOUR_POLICY_ORDER) ||
        error("Checkpoint row count is inconsistent with completed cases.")

    return completed_case_ids
end


function _grid_check(
    data::DataFrame,
    scenario_index::Integer,
    requested_case_ids::Set{Int},
    completed_case_ids::Set{Int},
    new_cases::Integer,
    block_start::Real
)
    instance_timings = unique(
        select(
            data,
            :case_id,
            :plan_table_seconds,
            :simulation_seconds
        )
    )

    unique_fallback_counts = unique(
        select(data, :case_id, :lwz_fallback_count)
    )

    completed_requested = length(intersect(
        completed_case_ids,
        requested_case_ids
    ))

    return DataFrame([(
        scenario_index=Int(scenario_index),
        completed_instances_full_scenario=length(completed_case_ids),
        expected_instances_full_scenario=
            length(_PROP_A_VALUES) *
            length(_ALPHAM_VALUES) *
            length(FOUR_POLICY_GRID_N_VALUES),
        completed_instances_requested=completed_requested,
        expected_instances_requested=length(requested_case_ids),
        policy_rows=nrow(data),
        new_instances_this_run=Int(new_cases),
        total_plan_table_seconds=
            sum(instance_timings.plan_table_seconds),
        total_simulation_seconds=
            sum(instance_timings.simulation_seconds),
        wall_minutes_this_run=(time() - block_start) / 60,
        all_rewards_finite=all(data.all_rewards_finite),
        all_priorities_finite=all(data.all_priorities_finite),
        exact_capacity_ok=all(data.exact_capacity_ok),
        total_lwz_fallback_count=
            sum(unique_fallback_counts.lwz_fallback_count),
        minimum_conservative_gap_to_conditional_bound=
            minimum(data.conservative_gap_to_bound)
    )])
end


"""
    run_four_policy_grid_scenario(scenario_index; pcl_callbacks, mp_index_fn, ...)

Run one of the 12 paper scenarios with case-level atomic checkpointing. By
default, all five population sizes are requested. For scenario 1, the validated
five-policy N=100 smoke CSV is imported automatically, with its
Lagrangian-threshold rows removed, when the scenario checkpoint does not yet
exist. Thus, the 72 previously completed cases are reused without simulating
the discarded policy or any retained policy again.

Use `max_new_cases=1` for a short preflight.  Rerunning the same call resumes
from the checkpoint and never repeats a complete case.
"""
function run_four_policy_grid_scenario(
    scenario_index::Integer;
    pcl_callbacks,
    mp_index_fn,
    N_values::AbstractVector{<:Integer}=FOUR_POLICY_GRID_N_VALUES,
    beta::Real=0.99,
    T::Integer=700,
    nruns::Integer=1_000,
    base_seed::Integer=20260810,
    x_initial::Real=0.5,
    table_nx::Integer=4001,
    lwz_iterations::Integer=4,
    lwz_fallback::Symbol=:liu_paper,
    output_file::Union{Nothing,AbstractString}=nothing,
    smoke_file::Union{Nothing,AbstractString}=nothing,
    import_scenario1_smoke::Bool=true,
    max_new_cases::Union{Nothing,Integer}=nothing,
    threaded::Bool=true
)
    1 <= scenario_index <= 12 ||
        throw(ArgumentError("scenario_index must lie in 1:12."))
    T >= 1 || throw(ArgumentError("T must be positive."))
    nruns >= 2 || throw(ArgumentError("nruns must be at least 2."))
    table_nx >= 2 || throw(ArgumentError("table_nx must be at least 2."))
    lwz_iterations >= 1 ||
        throw(ArgumentError("lwz_iterations must be positive."))
    max_new_cases === nothing || max_new_cases >= 0 ||
        throw(ArgumentError("max_new_cases must be nonnegative."))

    requested_set = Set(Int.(N_values))
    isempty(requested_set) &&
        throw(ArgumentError("N_values must not be empty."))

    all(N -> N in FOUR_POLICY_GRID_N_VALUES, requested_set) ||
        throw(ArgumentError(
            "N_values must be selected from $(FOUR_POLICY_GRID_N_VALUES)."
        ))

    requested_N_values = [
        N for N in FOUR_POLICY_GRID_N_VALUES if N in requested_set
    ]

    scenarios = four_policy_grid_scenarios(; beta=beta)
    scenario = scenarios[Int(scenario_index)]

    output_path = output_file === nothing ?
        _default_output_file(scenario_index, T, nruns) :
        String(output_file)

    smoke_path = smoke_file === nothing ?
        _default_legacy_smoke_file(T, nruns) :
        String(smoke_file)

    imported_smoke = false

    if isfile(output_path)
        grid = CSV.read(output_path, DataFrame)
    elseif Int(scenario_index) == 1 &&
           import_scenario1_smoke &&
           isfile(smoke_path)
        grid = CSV.read(smoke_path, DataFrame)
        :policy in propertynames(grid) ||
            error("The smoke checkpoint has no policy column: $smoke_path")

        legacy_policies = Set(String.(grid.policy))
        expected_legacy_policies = Set([
            "mp_index",
            "myopic",
            "lwz4",
            "lagrangian",
            "lagrangian_forced"
        ])

        legacy_policies == expected_legacy_policies ||
            error(
                "The smoke checkpoint does not contain the validated " *
                "five-policy set: $smoke_path"
            )

        filter!(row -> String(row.policy) != "lagrangian", grid)

        if :runner_revision in propertynames(grid)
            grid[!, :source_runner_revision] = String.(grid.runner_revision)
            select!(grid, Not(:runner_revision))
        else
            grid[!, :source_runner_revision] =
                fill("2026-08-03-five-policy-smoke-v1", nrow(grid))
        end

        if :forced_capacity_ok in propertynames(grid)
            grid[!, :exact_capacity_ok] = Bool.(grid.forced_capacity_ok)
            select!(grid, Not(:forced_capacity_ok))
        end

        grid[!, :simulation_source_policy_count] = fill(5, nrow(grid))
        grid[!, :reused_from_five_policy_smoke] = fill(true, nrow(grid))
        imported_smoke = true
    else
        grid = DataFrame()
    end

    _enrich_checkpoint!(
        grid,
        scenario_index,
        scenario;
        x_initial=x_initial,
        table_nx=table_nx,
        lwz_iterations=lwz_iterations,
        lwz_fallback=lwz_fallback
    )

    completed_case_ids = _validate_checkpoint(
        grid,
        scenario_index,
        scenario;
        T=T,
        nruns=nruns,
        beta=beta,
        base_seed=base_seed
    )

    if imported_smoke
        sort!(grid, [:case_id, :policy])
        _atomic_csv_write(output_path, grid)
        println(
            "Imported $(length(completed_case_ids)) validated cases from " *
            "$smoke_path into $output_path."
        )
    end

    requested_case_ids = Set(
        four_policy_grid_case_id(
            scenario_index,
            prop_index,
            alpha_index,
            N_index
        )
        for prop_index in eachindex(_PROP_A_VALUES),
            alpha_index in eachindex(_ALPHAM_VALUES),
            N_index in eachindex(FOUR_POLICY_GRID_N_VALUES)
        if FOUR_POLICY_GRID_N_VALUES[N_index] in requested_set
    )

    pending_case_ids = setdiff(requested_case_ids, completed_case_ids)
    block_start = time()

    if isempty(pending_case_ids) || max_new_cases == 0
        grid_check = _grid_check(
            grid,
            scenario_index,
            requested_case_ids,
            completed_case_ids,
            0,
            block_start
        )

        @show abspath(output_path)
        display(grid_check)

        return (
            grid=grid,
            grid_check=grid_check,
            manifest=four_policy_grid_manifest(; beta=beta),
            output_file=output_path,
            imported_smoke=imported_smoke
        )
    end

    setup_tables_start = time()

    mp_tables = build_mp_tables(
        scenario.types,
        mp_index_fn;
        nx=table_nx,
        labels=scenario.labels
    )

    lwz_tables = build_lwz_tables(
        scenario.types;
        nx=table_nx,
        iterations=lwz_iterations,
        fallback=lwz_fallback,
        labels=scenario.labels
    )

    shared_table_seconds = time() - setup_tables_start

    new_cases = 0
    stop_requested = false

    for (prop_index, p_A) in enumerate(_PROP_A_VALUES)
        stop_requested && break

        for (alpha_index, alphaM) in enumerate(_ALPHAM_VALUES)
            stop_requested && break

            for N in requested_N_values
                N_index = _grid_N_index(N)

                case_id = four_policy_grid_case_id(
                    scenario_index,
                    prop_index,
                    alpha_index,
                    N_index
                )

                case_id in completed_case_ids && continue

                if max_new_cases !== nothing &&
                   new_cases >= Int(max_new_cases)
                    stop_requested = true
                    break
                end

                M = round(Int, alphaM * N)
                n_A = round(Int, p_A * N)

                type_of_plan = vcat(
                    fill(1, n_A),
                    fill(2, N - n_A)
                )

                initial_beliefs = fill(Float64(x_initial), N)
                instance_seed = Int(base_seed) + case_id

                type_of_simulation = copy(type_of_plan)
                shuffle!(
                    MersenneTwister(instance_seed + 50_000_000),
                    type_of_simulation
                )

                setup_start = time()

                plan = solve_lagrangian_plan(
                    initial_beliefs,
                    type_of_plan,
                    scenario.types,
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
                    nx=table_nx,
                    labels=scenario.labels
                )

                plan_table_seconds = time() - setup_start

                result = run_four_policy_pilot(
                    initial_beliefs,
                    type_of_simulation,
                    scenario.types,
                    M;
                    mp_tables=mp_tables,
                    lwz_tables=lwz_tables,
                    lagrangian_tables=lagrangian_tables,
                    T=T,
                    nruns=nruns,
                    seed=instance_seed,
                    threaded=threaded,
                    verify_reproducibility=false
                )

                result.all_rewards_finite ||
                    error("Nonfinite reward in case $case_id.")

                result.all_priorities_finite ||
                    error("Nonfinite priority in case $case_id.")

                exact_capacity_ok = true

                for j in eachindex(result.policies)
                    capacity_row = result.capacity[j]

                    exact_capacity_ok &=
                        capacity_row.min_active == M &&
                        capacity_row.max_active == M
                end

                exact_capacity_ok ||
                    error("Capacity validation failed in case $case_id.")

                mp_column = findfirst(==(:mp_index), result.policies)
                mp_mean = result.summary[mp_column].mean
                tcrit = quantile(TDist(result.nruns - 1), 0.975)
                conditional_bound = plan.normalized_value

                tail_upper =
                    result.beta_tail *
                    (M / N) *
                    maximum(project_type.r for project_type in scenario.types)

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
                        paired_stderr =
                            std(differences) / sqrt(result.nruns)
                        paired_ci_low =
                            paired_mean - tcrit * paired_stderr
                        paired_ci_high =
                            paired_mean + tcrit * paired_stderr

                        if paired_stderr == 0.0
                            paired_pvalue =
                                paired_mean == 0.0 ? 1.0 : 0.0
                        else
                            tstat = paired_mean / paired_stderr
                            paired_pvalue =
                                2 * ccdf(
                                    TDist(result.nruns - 1),
                                    abs(tstat)
                                )
                        end

                        relative_difference_vs_mp =
                            paired_mean / mp_mean
                    end

                    upper_95_with_tail = ci_high + tail_upper

                    push!(
                        case_rows,
                        (
                            case_id=case_id,
                            scenario_index=Int(scenario_index),
                            scenario=scenario.name,
                            prop_index=prop_index,
                            p_A=p_A,
                            p_B=1.0 - p_A,
                            alpha_index=alpha_index,
                            alphaM_target=alphaM,
                            N=N,
                            N_index=N_index,
                            M=M,
                            capacity_ratio=M / N,
                            T=result.T,
                            nruns=result.nruns,
                            beta=result.beta,
                            beta_tail=result.beta_tail,
                            seed=instance_seed,

                            runner_revision=_RUNNER_REVISION,
                            source_runner_revision=_RUNNER_REVISION,
                            simulation_source_policy_count=4,
                            reused_from_five_policy_smoke=false,
                            x_initial=Float64(x_initial),
                            table_nx=Int(table_nx),
                            lwz_iterations=Int(lwz_iterations),
                            lwz_fallback=String(lwz_fallback),
                            p01_type_A=scenario.A.p01,
                            rho_type_A=scenario.A.rho,
                            kappa_type_A=scenario.A.kappa,
                            reward_type_A=scenario.A.r,
                            p01_type_B=scenario.B.p01,
                            rho_type_B=scenario.B.rho,
                            kappa_type_B=scenario.B.kappa,
                            reward_type_B=scenario.B.r,

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
                            conditional_lagrangian_bound=
                                conditional_bound,
                            bound_value_is_certified=
                                plan.value_is_certified,
                            bound_status=_BOUND_STATUS,
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

                            shared_table_seconds=shared_table_seconds,
                            plan_table_seconds=plan_table_seconds,
                            simulation_seconds=result.elapsed_seconds,
                            seconds_per_replication=
                                result.seconds_per_replication,
                            julia_threads=Threads.nthreads(),
                            lwz_fallback_count=result.lwz_fallback_count,
                            all_rewards_finite=
                                result.all_rewards_finite,
                            all_priorities_finite=
                                result.all_priorities_finite,
                            exact_capacity_ok=exact_capacity_ok
                        )
                    )
                end

                case_df = DataFrame(case_rows)

                if nrow(grid) == 0
                    grid = case_df
                else
                    grid = vcat(grid, case_df; cols=:union)
                end

                sort!(grid, [:case_id, :policy])
                _atomic_csv_write(output_path, grid)

                push!(completed_case_ids, case_id)
                new_cases += 1

                println(
                    "[$(length(completed_case_ids))/360; " *
                    "requested $(length(intersect(completed_case_ids, requested_case_ids)))" *
                    "/$(length(requested_case_ids))] " *
                    "scenario=$(Int(scenario_index)), p_A=$p_A, " *
                    "alpha=$alphaM, N=$N, M=$M, " *
                    "setup=$(round(plan_table_seconds; digits=2)) s, " *
                    "simulation=$(round(result.elapsed_seconds; digits=2)) s, " *
                    "elapsed=$(round((time() - block_start) / 60; digits=1)) min"
                )
            end
        end
    end

    completed_case_ids = _validate_checkpoint(
        grid,
        scenario_index,
        scenario;
        T=T,
        nruns=nruns,
        beta=beta,
        base_seed=base_seed
    )

    grid_check = _grid_check(
        grid,
        scenario_index,
        requested_case_ids,
        completed_case_ids,
        new_cases,
        block_start
    )

    @show abspath(output_path)
    display(grid_check)

    return (
        grid=grid,
        grid_check=grid_check,
        manifest=four_policy_grid_manifest(; beta=beta),
        output_file=output_path,
        imported_smoke=imported_smoke
    )
end


"""
Combine the 12 complete scenario checkpoints into one final CSV.  The function
refuses to combine incomplete scenario files unless `require_complete=false`.
"""
function combine_four_policy_grid_outputs(
    ;
    beta::Real=0.99,
    T::Integer=700,
    nruns::Integer=1_000,
    base_seed::Integer=20260810,
    directory::AbstractString=pwd(),
    output_file::AbstractString=
        "four_policy_grid_all_T700_n1000_v1.csv",
    require_complete::Bool=true
)
    scenarios = four_policy_grid_scenarios(; beta=beta)
    frames = DataFrame[]

    for scenario_index in eachindex(scenarios)
        path = joinpath(
            directory,
            _default_output_file(scenario_index, T, nruns)
        )

        isfile(path) ||
            error("Missing scenario checkpoint: $path")

        data = CSV.read(path, DataFrame)
        completed = _validate_checkpoint(
            data,
            scenario_index,
            scenarios[scenario_index];
            T=T,
            nruns=nruns,
            beta=beta,
            base_seed=base_seed
        )

        if require_complete && length(completed) != 360
            error(
                "Scenario $scenario_index is incomplete: " *
                "$(length(completed))/360 cases."
            )
        end

        push!(frames, data)
    end

    combined = reduce(
        (left, right) -> vcat(left, right; cols=:union),
        frames
    )

    sort!(combined, [:case_id, :policy])
    combined_path = joinpath(directory, output_file)
    _atomic_csv_write(combined_path, combined)

    combine_check = DataFrame([(
        scenarios=length(frames),
        completed_instances=length(unique(combined.case_id)),
        expected_instances=12 * 360,
        policy_rows=nrow(combined),
        expected_policy_rows=12 * 360 * length(FOUR_POLICY_ORDER),
        all_rewards_finite=all(combined.all_rewards_finite),
        all_priorities_finite=all(combined.all_priorities_finite),
        exact_capacity_ok=all(combined.exact_capacity_ok),
        minimum_conservative_gap_to_conditional_bound=
            minimum(combined.conservative_gap_to_bound)
    )])

    @show abspath(combined_path)
    display(combine_check)

    return (
        combined=combined,
        combine_check=combine_check,
        output_file=combined_path
    )
end


end # module FourPolicyFullGridRkappa
