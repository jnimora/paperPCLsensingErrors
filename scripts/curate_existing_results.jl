#!/usr/bin/env julia

# curate_paperPCLsensingErrors_results_v1.jl
#
# Build a curated processed-data layer and machine-readable validation
# reports from the already completed experiments for paperPCLsensingErrors.
#
# This script never modifies files under reproducibility/data/raw,
# reproducibility/data/supporting, clean_benchmark_v4, or the imported
# provenance directories. It writes only under:
#
#   reproducibility/data/processed
#   reproducibility/data/checks
#   reproducibility/provenance/curation_v1
#
# It performs no Git operation and reruns no simulation or PCLI grid.
#
# Run from the repository root:
#
#   julia --project=. C:\Users\JNINO\Downloads\
#       curate_paperPCLsensingErrors_results_v1.jl .
#
# The final argument is the repository root. If omitted, the script first
# tries the parent of @__DIR__, then the current working directory.

using CSV
using DataFrames
using Dates
using Printf
using SHA
using Statistics

const EXPECTED_FOUR_POLICIES = Set([
    "mp_index",
    "myopic",
    "lwz4",
    "lagrangian_forced",
])

const EXPECTED_FOUR_POLICY_BOUND_STATUS =
    "conditional on global PCL-indexability"

const CHECK_ROWS = NamedTuple[]
const SUMMARY_ROWS = NamedTuple[]


# ---------------------------------------------------------------------------
# Paths and low-level helpers
# ---------------------------------------------------------------------------

function resolve_repo_root()
    candidates = String[]

    if !isempty(ARGS)
        push!(candidates, abspath(ARGS[1]))
    end

    push!(candidates, normpath(joinpath(@__DIR__, "..")))
    push!(candidates, abspath(pwd()))

    for candidate in unique(candidates)
        if isdir(joinpath(candidate, ".git")) &&
           isdir(joinpath(candidate, "reproducibility")) &&
           isfile(joinpath(candidate, "Project.toml"))
            return candidate
        end
    end

    error(
        "Could not locate the paperPCLsensingErrors repository. " *
        "Pass its root directory as the first command-line argument."
    )
end


function require_file(path::AbstractString)
    isfile(path) || error("Required file is missing: $path")
    return path
end


function require_directory(path::AbstractString)
    isdir(path) || error("Required directory is missing: $path")
    return path
end


function require_columns(
    data::DataFrame,
    columns::AbstractVector{Symbol},
    label::AbstractString,
)
    missing_columns = setdiff(Set(columns), Set(propertynames(data)))

    isempty(missing_columns) || error(
        "$label is missing required columns: " *
        join(sort!(string.(collect(missing_columns))), ", ")
    )

    return nothing
end


function atomic_csv_write(path::AbstractString, data::DataFrame)
    mkpath(dirname(path))
    temporary = path * ".tmp"
    CSV.write(temporary, data)
    mv(temporary, path; force=true)
    return path
end


function atomic_text_write(path::AbstractString, text::AbstractString)
    mkpath(dirname(path))
    temporary = path * ".tmp"
    open(temporary, "w") do io
        write(io, text)
    end
    mv(temporary, path; force=true)
    return path
end


function sha256_hex(path::AbstractString)
    require_file(path)

    digest = open(path, "r") do io
        SHA.sha256(io)
    end

    return uppercase(bytes2hex(digest))
end


function dataframe_exactly_equal(left::DataFrame, right::DataFrame)
    names(left) == names(right) || return false
    nrow(left) == nrow(right) || return false

    for column in propertynames(left)
        isequal(left[!, column], right[!, column]) || return false
    end

    return true
end


function canonical_sorted_copy(
    data::DataFrame,
    keys::AbstractVector{Symbol},
)
    copy_data = copy(data)
    sort!(copy_data, keys)
    return copy_data
end


function first_existing_column(
    data::DataFrame,
    candidates::AbstractVector{Symbol},
)
    available = Set(propertynames(data))

    for candidate in candidates
        candidate in available && return candidate
    end

    return nothing
end


function safe_minimum(column)
    values = collect(skipmissing(column))
    isempty(values) && return missing
    return minimum(values)
end


function safe_maximum(column)
    values = collect(skipmissing(column))
    isempty(values) && return missing
    return maximum(values)
end


function all_finite(column)
    return all(value -> ismissing(value) || isfinite(Float64(value)), column)
end


function add_check!(
    dataset::AbstractString,
    check::AbstractString,
    passed::Bool,
    value,
    expected;
    note::AbstractString="",
)
    push!(
        CHECK_ROWS,
        (
            dataset=String(dataset),
            check=String(check),
            status=passed ? "PASS" : "FAIL",
            value=string(value),
            expected=string(expected),
            note=String(note),
        ),
    )

    return passed
end


function add_summary!(
    dataset::AbstractString;
    source::AbstractString,
    output::AbstractString,
    rows,
    columns,
    note::AbstractString="",
)
    push!(
        SUMMARY_ROWS,
        (
            dataset=String(dataset),
            source=String(source),
            output=String(output),
            rows=Int(rows),
            columns=Int(columns),
            note=String(note),
        ),
    )

    return nothing
end


function renamed_legacy_copy(data::DataFrame)
    output = copy(data)

    mapping = Pair{Symbol,Symbol}[
        :q => :p01,
        Symbol("ρ") => :rho,
        Symbol("κ") => :kappa,
        Symbol("β") => :beta,
        Symbol("Δx1_left") => :delta_x1_left,
        Symbol("Δx1_right") => :delta_x1_right,
        Symbol("Δx0_left") => :delta_x0_left,
        Symbol("Δx0_right") => :delta_x0_right,
    ]

    available = Set(propertynames(output))

    for (old_name, new_name) in mapping
        if old_name in available
            new_name in available && error(
                "Cannot rename $old_name to $new_name because both exist."
            )
            rename!(output, old_name => new_name)
            delete!(available, old_name)
            push!(available, new_name)
        end
    end

    return output
end


function list_files_recursively(directory::AbstractString)
    files = String[]

    for (root, _, names_here) in walkdir(directory)
        for name in names_here
            push!(files, joinpath(root, name))
        end
    end

    sort!(files)
    return files
end


# ---------------------------------------------------------------------------
# Four-policy heterogeneous grid
# ---------------------------------------------------------------------------

function curate_four_policy_grid(
    raw_directory::AbstractString,
    processed_directory::AbstractString,
)
    dataset = "four_policy_grid"

    paths = [
        joinpath(
            raw_directory,
            @sprintf("four_policy_grid_s%02d_T700_n1000_v1.csv", index),
        )
        for index in 1:12
    ]

    frames = DataFrame[]

    required = Symbol[
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
        :seed,
        :policy,
        :mean_reward,
        :stderr,
        :conditional_lagrangian_bound,
        :bound_value_is_certified,
        :bound_status,
        :conservative_gap_to_bound,
        :all_rewards_finite,
        :all_priorities_finite,
        :exact_capacity_ok,
    ]

    for (scenario_index, path) in enumerate(paths)
        require_file(path)
        data = CSV.read(path, DataFrame)
        require_columns(
            data,
            required,
            "four-policy scenario $scenario_index",
        )

        groups = groupby(data, :case_id)
        scenario_policy_set = Set(String.(data.policy))

        add_check!(
            dataset,
            "scenario $(scenario_index) row count",
            nrow(data) == 1_440,
            nrow(data),
            1_440,
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) completed cases",
            length(groups) == 360,
            length(groups),
            360,
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) index",
            unique(Int.(data.scenario_index)) == [scenario_index],
            unique(Int.(data.scenario_index)),
            [scenario_index],
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) policy set",
            scenario_policy_set == EXPECTED_FOUR_POLICIES,
            sort!(collect(scenario_policy_set)),
            sort!(collect(EXPECTED_FOUR_POLICIES)),
        )

        complete_cases = all(
            group ->
                nrow(group) == 4 &&
                Set(String.(group.policy)) == EXPECTED_FOUR_POLICIES,
            groups,
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) complete policy rows per case",
            complete_cases,
            complete_cases,
            true,
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) finite rewards",
            all_finite(data.mean_reward) && all_finite(data.stderr),
            all_finite(data.mean_reward) && all_finite(data.stderr),
            true,
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) numerical flags",
            all(Bool.(data.all_rewards_finite)) &&
            all(Bool.(data.all_priorities_finite)) &&
            all(Bool.(data.exact_capacity_ok)),
            (
                all_rewards_finite=all(Bool.(data.all_rewards_finite)),
                all_priorities_finite=all(
                    Bool.(data.all_priorities_finite)
                ),
                exact_capacity_ok=all(Bool.(data.exact_capacity_ok)),
            ),
            "all true",
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) conditional-bound status",
            all(.!Bool.(data.bound_value_is_certified)) &&
            all(
                String.(data.bound_status) .==
                EXPECTED_FOUR_POLICY_BOUND_STATUS
            ),
            (
                any_certified=any(Bool.(data.bound_value_is_certified)),
                statuses=unique(String.(data.bound_status)),
            ),
            (
                any_certified=false,
                status=EXPECTED_FOUR_POLICY_BOUND_STATUS,
            ),
        )

        add_check!(
            dataset,
            "scenario $(scenario_index) design constants",
            unique(Int.(data.T)) == [700] &&
            unique(Int.(data.nruns)) == [1_000] &&
            all(
                beta ->
                    isapprox(
                        beta,
                        0.99;
                        atol=0.0,
                        rtol=1e-14,
                    ),
                unique(Float64.(data.beta)),
            ),
            (
                T=unique(Int.(data.T)),
                nruns=unique(Int.(data.nruns)),
                beta=unique(Float64.(data.beta)),
            ),
            (T=700, nruns=1_000, beta=0.99),
        )

        push!(frames, data)
    end

    combined = reduce(
        (left, right) -> vcat(left, right; cols=:union),
        frames,
    )

    sort!(combined, [:case_id, :policy])

    case_ids = Set(Int.(combined.case_id))
    case_groups = groupby(combined, :case_id)
    unique_case_policy_rows =
        nrow(unique(select(combined, [:case_id, :policy])))

    add_check!(
        dataset,
        "combined scenario count",
        length(unique(Int.(combined.scenario_index))) == 12,
        length(unique(Int.(combined.scenario_index))),
        12,
    )

    add_check!(
        dataset,
        "combined case count",
        length(case_ids) == 4_320,
        length(case_ids),
        4_320,
    )

    add_check!(
        dataset,
        "combined case-id coverage",
        case_ids == Set(1:4_320),
        (
            minimum=minimum(case_ids),
            maximum=maximum(case_ids),
            count=length(case_ids),
        ),
        "all integers 1:4320",
    )

    add_check!(
        dataset,
        "combined policy-row count",
        nrow(combined) == 17_280,
        nrow(combined),
        17_280,
    )

    add_check!(
        dataset,
        "combined unique case-policy rows",
        unique_case_policy_rows == 17_280,
        unique_case_policy_rows,
        17_280,
    )

    add_check!(
        dataset,
        "combined complete cases",
        all(
            group ->
                nrow(group) == 4 &&
                Set(String.(group.policy)) == EXPECTED_FOUR_POLICIES,
            case_groups,
        ),
        all(
            group ->
                nrow(group) == 4 &&
                Set(String.(group.policy)) == EXPECTED_FOUR_POLICIES,
            case_groups,
        ),
        true,
    )

    output_path = joinpath(
        processed_directory,
        "four_policy_grid_all_T700_n1000_v1.csv",
    )
    atomic_csv_write(output_path, combined)

    manifest_columns = Symbol[
        :scenario_index,
        :scenario,
        :p01_type_A,
        :rho_type_A,
        :kappa_type_A,
        :reward_type_A,
        :p01_type_B,
        :rho_type_B,
        :kappa_type_B,
        :reward_type_B,
        :beta,
    ]

    if all(column -> column in propertynames(combined), manifest_columns)
        scenario_manifest = unique(select(combined, manifest_columns))
        sort!(scenario_manifest, :scenario_index)

        atomic_csv_write(
            joinpath(
                processed_directory,
                "four_policy_scenario_manifest_v1.csv",
            ),
            scenario_manifest,
        )
    end

    add_summary!(
        dataset;
        source=raw_directory,
        output=output_path,
        rows=nrow(combined),
        columns=ncol(combined),
        note=(
            "12 scenarios, 4,320 cases, four retained policies; " *
            "conditional benchmark is not marked as certified."
        ),
    )

    return combined
end


# ---------------------------------------------------------------------------
# Homogeneous-project tie diagnostic
# ---------------------------------------------------------------------------

function curate_homogeneous_ties(
    raw_path::AbstractString,
    processed_directory::AbstractString,
)
    dataset = "homogeneous_ties_v2"
    require_file(raw_path)

    data = CSV.read(raw_path, DataFrame)

    require_columns(
        data,
        Symbol[
            :case_id,
            :profile_index,
            :profile,
            :alpha_index,
            :alphaM_target,
            :N,
            :N_index,
            :M,
            :T,
            :nruns,
            :beta,
            :seed,
            :policy,
            :mean_reward,
            :mp_table_nonnegative,
            :mp_table_nondecreasing,
            :all_rewards_finite,
            :all_priorities_finite,
            :exact_capacity_ok,
        ],
        dataset,
    )

    groups = groupby(data, :case_id)
    policy_set = Set(String.(data.policy))

    add_check!(
        dataset,
        "row count",
        nrow(data) == 672,
        nrow(data),
        672,
    )

    add_check!(
        dataset,
        "case count",
        length(groups) == 168,
        length(groups),
        168,
    )

    add_check!(
        dataset,
        "four policies per case",
        all(group -> nrow(group) == 4, groups) &&
        length(policy_set) == 4,
        (
            policies=sort!(collect(policy_set)),
            all_groups_have_four=all(
                group -> nrow(group) == 4,
                groups,
            ),
        ),
        "four distinct policies in every case",
    )

    add_check!(
        dataset,
        "design dimensions",
        length(unique(Int.(data.profile_index))) == 7 &&
        length(unique(Int.(data.alpha_index))) == 8 &&
        sort(unique(Int.(data.N))) == [100, 400, 1_600],
        (
            profiles=length(unique(Int.(data.profile_index))),
            capacity_levels=length(unique(Int.(data.alpha_index))),
            N_values=sort(unique(Int.(data.N))),
        ),
        (
            profiles=7,
            capacity_levels=8,
            N_values=[100, 400, 1_600],
        ),
    )

    add_check!(
        dataset,
        "design constants",
        unique(Int.(data.T)) == [700] &&
        unique(Int.(data.nruns)) == [1_000] &&
        all(
            beta ->
                isapprox(
                    beta,
                    0.99;
                    atol=0.0,
                    rtol=1e-14,
                ),
            unique(Float64.(data.beta)),
        ),
        (
            T=unique(Int.(data.T)),
            nruns=unique(Int.(data.nruns)),
            beta=unique(Float64.(data.beta)),
        ),
        (T=700, nruns=1_000, beta=0.99),
    )

    add_check!(
        dataset,
        "finite values and exact capacity",
        all(Bool.(data.all_rewards_finite)) &&
        all(Bool.(data.all_priorities_finite)) &&
        all(Bool.(data.exact_capacity_ok)),
        (
            all_rewards_finite=all(Bool.(data.all_rewards_finite)),
            all_priorities_finite=all(
                Bool.(data.all_priorities_finite)
            ),
            exact_capacity_ok=all(Bool.(data.exact_capacity_ok)),
        ),
        "all true",
    )

    add_check!(
        dataset,
        "MP-table positivity and monotonicity",
        all(Bool.(data.mp_table_nonnegative)) &&
        all(Bool.(data.mp_table_nondecreasing)),
        (
            nonnegative=all(Bool.(data.mp_table_nonnegative)),
            nondecreasing=all(
                Bool.(data.mp_table_nondecreasing)
            ),
        ),
        "all true",
    )

    adjacent_difference_column = first_existing_column(
        data,
        Symbol[
            :mp_table_minimum_adjacent_difference,
            :minimum_mp_table_adjacent_difference,
        ],
    )

    if adjacent_difference_column !== nothing
        minimum_adjacent_difference = minimum(
            Float64.(data[!, adjacent_difference_column])
        )

        add_check!(
            dataset,
            "strict sampled MP-table increase",
            minimum_adjacent_difference > 0.0,
            minimum_adjacent_difference,
            "> 0",
        )
    end

    mismatch_column = first_existing_column(
        data,
        Symbol[
            :mp_random_action_mismatch_periods,
            :mp_belief_random_action_mismatch_periods,
            :mp_fixed_action_mismatch_periods,
        ],
    )

    mismatch_column === nothing && error(
        "$dataset has no recognized MP/belief action-mismatch column."
    )

    mismatch_by_case = unique(
        select(data, :case_id, mismatch_column)
    )
    total_mismatches = sum(
        Int.(mismatch_by_case[!, mismatch_column])
    )

    add_check!(
        dataset,
        "MP/belief action mismatches",
        total_mismatches == 0,
        total_mismatches,
        0,
        note=(
            "The v2 file is expected to compare the lexicographic MP " *
            "rule with randomized belief ranking."
        ),
    )

    rewards_exact_column = first_existing_column(
        data,
        Symbol[
            :mp_random_rewards_exact,
            :mp_belief_random_rewards_exact,
            :mp_fixed_rewards_exact,
        ],
    )

    rewards_exact_column === nothing && error(
        "$dataset has no recognized MP/belief exact-reward column."
    )

    add_check!(
        dataset,
        "MP/belief replication rewards exactly equal",
        all(Bool.(data[!, rewards_exact_column])),
        all(Bool.(data[!, rewards_exact_column])),
        true,
    )

    output_path = joinpath(
        processed_directory,
        "homogeneous_tie_grid_T700_n1000_v2.csv",
    )
    mkpath(dirname(output_path))
    cp(raw_path, output_path; force=true)

    add_summary!(
        dataset;
        source=raw_path,
        output=output_path,
        rows=nrow(data),
        columns=ncol(data),
        note=(
            "168 homogeneous cases and four tie-rule/policy rows per case."
        ),
    )

    return data
end


# ---------------------------------------------------------------------------
# Boundary-focused PCLI stress test
# ---------------------------------------------------------------------------

function validate_boundary_stress(
    raw_directory::AbstractString,
    checks_directory::AbstractString,
)
    dataset = "pcli_boundary_stress_v1"

    file_names = [
        "pcli_boundary_stress_v1_check.csv",
        "pcli_boundary_stress_v1_coarse.csv",
        "pcli_boundary_stress_v1_near_tolerance_counts.csv",
        "pcli_boundary_stress_v1_quantiles.csv",
        "pcli_boundary_stress_v1_refined_pcli1.csv",
        "pcli_boundary_stress_v1_refined_pcli2.csv",
    ]

    for name in file_names
        require_file(joinpath(raw_directory, name))
    end

    check_path = joinpath(
        raw_directory,
        "pcli_boundary_stress_v1_check.csv",
    )

    check = CSV.read(check_path, DataFrame)
    nrow(check) == 1 || error(
        "Boundary-stress check file must have exactly one row."
    )

    required = Symbol[
        :completed_parameter_tuples,
        :expected_parameter_tuples,
        :coarse_grid_complete,
        :all_pcli1_slacks_nonnegative,
        :all_pcli2_secant_slopes_nonnegative,
        :all_sampled_marginal_work_positive,
        :refined_pcli1_slacks_nonnegative,
        :refined_pcli2_secant_slopes_nonnegative,
        :minimum_pcli1_slack,
        :minimum_pcli2_core_slope,
        :minimum_pcli2_all_slope,
        :refined_minimum_pcli1_slack,
        :refined_minimum_pcli2_core_slope,
        :refined_minimum_pcli2_all_slope,
    ]

    require_columns(check, required, dataset)
    row = check[1, :]

    add_check!(
        dataset,
        "coarse tuple completion",
        Int(row.completed_parameter_tuples) == 320 &&
        Int(row.expected_parameter_tuples) == 320 &&
        Bool(row.coarse_grid_complete),
        (
            completed=Int(row.completed_parameter_tuples),
            expected=Int(row.expected_parameter_tuples),
            complete=Bool(row.coarse_grid_complete),
        ),
        (completed=320, expected=320, complete=true),
    )

    boolean_fields = Symbol[
        :all_pcli1_slacks_nonnegative,
        :all_pcli2_secant_slopes_nonnegative,
        :all_sampled_marginal_work_positive,
        :refined_pcli1_slacks_nonnegative,
        :refined_pcli2_secant_slopes_nonnegative,
    ]

    for field in boolean_fields
        add_check!(
            dataset,
            String(field),
            Bool(row[field]),
            Bool(row[field]),
            true,
        )
    end

    add_check!(
        dataset,
        "strictly positive reported minima",
        Float64(row.minimum_pcli1_slack) > 0.0 &&
        Float64(row.minimum_pcli2_core_slope) > 0.0 &&
        Float64(row.minimum_pcli2_all_slope) > 0.0 &&
        Float64(row.refined_minimum_pcli1_slack) > 0.0 &&
        Float64(row.refined_minimum_pcli2_core_slope) > 0.0 &&
        Float64(row.refined_minimum_pcli2_all_slope) > 0.0,
        (
            coarse_pcli1=Float64(row.minimum_pcli1_slack),
            coarse_pcli2_core=Float64(
                row.minimum_pcli2_core_slope
            ),
            coarse_pcli2_all=Float64(
                row.minimum_pcli2_all_slope
            ),
            refined_pcli1=Float64(
                row.refined_minimum_pcli1_slack
            ),
            refined_pcli2_core=Float64(
                row.refined_minimum_pcli2_core_slope
            ),
            refined_pcli2_all=Float64(
                row.refined_minimum_pcli2_all_slope
            ),
        ),
        "all > 0",
    )

    copied_check = joinpath(
        checks_directory,
        "pcli_boundary_stress_v1_check.csv",
    )
    mkpath(dirname(copied_check))
    cp(check_path, copied_check; force=true)

    coarse = CSV.read(
        joinpath(raw_directory, "pcli_boundary_stress_v1_coarse.csv"),
        DataFrame,
    )

    add_summary!(
        dataset;
        source=raw_directory,
        output=copied_check,
        rows=nrow(coarse),
        columns=ncol(coarse),
        note=(
            "320 endpoint-focused parameter tuples plus automatic " *
            "PCLI1/PCLI2 refinements."
        ),
    )

    return check
end


# ---------------------------------------------------------------------------
# Broad PCLI1 and PCLI2 experiments imported from the MacBook
# ---------------------------------------------------------------------------

function load_chunk_union(
    directory::AbstractString,
    expected_chunk_count::Int,
)
    paths = sort(
        filter(
            path ->
                occursin(
                    r"^chunk_\d+\.csv$",
                    basename(path),
                ),
            list_files_recursively(directory),
        ),
    )

    length(paths) == expected_chunk_count || error(
        "Expected $expected_chunk_count chunk files in $directory; " *
        "found $(length(paths))."
    )

    frames = [CSV.read(path, DataFrame) for path in paths]

    combined = reduce(
        (left, right) -> vcat(left, right; cols=:setequal),
        frames,
    )

    return (
        data=combined,
        paths=paths,
    )
end


function curate_broad_pcli1(
    raw_directory::AbstractString,
    processed_directory::AbstractString,
)
    dataset = "pcli1_broad"

    full_path = require_file(
        joinpath(raw_directory, "all_results_sorted.csv")
    )
    worst_path = require_file(
        joinpath(raw_directory, "worst_200.csv")
    )

    full = CSV.read(full_path, DataFrame)
    worst = CSV.read(worst_path, DataFrame)

    legacy_keys = Symbol[
        :q,
        Symbol("ρ"),
        Symbol("κ"),
        Symbol("β"),
    ]

    require_columns(
        full,
        vcat(
            legacy_keys,
            Symbol[
                :x0,
                :x1,
                :min_slack,
                :rel_slack,
                :xstar,
                :zstar,
            ],
        ),
        dataset,
    )

    add_check!(
        dataset,
        "full row count",
        nrow(full) == 30_184,
        nrow(full),
        30_184,
    )

    add_check!(
        dataset,
        "worst-200 row count",
        nrow(worst) == 200,
        nrow(worst),
        200,
    )

    add_check!(
        dataset,
        "all sampled slacks nonnegative",
        minimum(Float64.(full.min_slack)) >= 0.0,
        minimum(Float64.(full.min_slack)),
        ">= 0",
    )

    manuscript_minimum = 2.60209967284708e-4
    actual_minimum = minimum(Float64.(full.min_slack))

    add_check!(
        dataset,
        "reported manuscript minimum reproduced",
        isapprox(
            actual_minimum,
            manuscript_minimum;
            atol=1e-15,
            rtol=1e-10,
        ),
        actual_minimum,
        manuscript_minimum,
    )

    add_check!(
        dataset,
        "worst-200 is leading full-table block",
        dataframe_exactly_equal(
            first(full, 200),
            worst,
        ),
        dataframe_exactly_equal(first(full, 200), worst),
        true,
    )

    chunks = load_chunk_union(raw_directory, 59)

    add_check!(
        dataset,
        "checkpoint chunk total rows",
        nrow(chunks.data) == 30_184,
        nrow(chunks.data),
        30_184,
    )

    add_check!(
        dataset,
        "checkpoint chunks reproduce final table",
        dataframe_exactly_equal(
            canonical_sorted_copy(chunks.data, legacy_keys),
            canonical_sorted_copy(full, legacy_keys),
        ),
        dataframe_exactly_equal(
            canonical_sorted_copy(chunks.data, legacy_keys),
            canonical_sorted_copy(full, legacy_keys),
        ),
        true,
    )

    processed_full = renamed_legacy_copy(full)
    processed_worst = renamed_legacy_copy(worst)

    processed_keys = Symbol[:p01, :rho, :kappa, :beta]
    sort!(processed_full, processed_keys)
    sort!(processed_worst, [:min_slack])

    output_full = joinpath(
        processed_directory,
        "pcli1_broad_all_results_p01.csv",
    )
    output_worst = joinpath(
        processed_directory,
        "pcli1_broad_worst_200_p01.csv",
    )

    atomic_csv_write(output_full, processed_full)
    atomic_csv_write(output_worst, processed_worst)

    add_summary!(
        dataset;
        source=raw_directory,
        output=output_full,
        rows=nrow(processed_full),
        columns=ncol(processed_full),
        note=(
            "Legacy raw column q denotes p01; processed columns use " *
            "p01, rho, kappa, and beta."
        ),
    )

    return (
        raw=full,
        processed=processed_full,
        minimum=actual_minimum,
        output=output_full,
    )
end


function curate_broad_pcli2(
    raw_directory::AbstractString,
    processed_directory::AbstractString,
)
    dataset = "pcli2_broad"

    all_path = require_file(
        joinpath(
            raw_directory,
            "all_results_sorted_by_min_diff_all.csv",
        )
    )
    core_path = require_file(
        joinpath(
            raw_directory,
            "all_results_sorted_by_min_diff_core.csv",
        )
    )
    endpoint_path = require_file(
        joinpath(
            raw_directory,
            "all_results_sorted_by_endpoint_cont_proxy_desc.csv",
        )
    )

    worst_all_path = require_file(
        joinpath(raw_directory, "worst_200_monotonicity.csv")
    )
    worst_core_path = require_file(
        joinpath(
            raw_directory,
            "worst_200_core_monotonicity.csv",
        )
    )
    worst_endpoint_path = require_file(
        joinpath(
            raw_directory,
            "worst_200_endpoint_continuity_proxy.csv",
        )
    )

    all_sorted = CSV.read(all_path, DataFrame)
    core_sorted = CSV.read(core_path, DataFrame)
    endpoint_sorted = CSV.read(endpoint_path, DataFrame)

    worst_all = CSV.read(worst_all_path, DataFrame)
    worst_core = CSV.read(worst_core_path, DataFrame)
    worst_endpoint = CSV.read(worst_endpoint_path, DataFrame)

    legacy_keys = Symbol[
        :q,
        Symbol("ρ"),
        Symbol("κ"),
        Symbol("β"),
    ]

    required = vcat(
        legacy_keys,
        Symbol[
            :x1,
            :x0,
            :xL,
            :xR,
            :n_x,
            :min_g_diag,
            :n_nonfinite_f,
            :n_nonfinite_g,
            :n_nonpositive_g,
            :n_nonfinite_m,
            :min_diff_all,
            :min_diff_core,
            :endpoint_cont_proxy,
            :mono_pass_all,
            :mono_pass_core,
            :mono_pass_endpoints,
        ],
    )

    require_columns(all_sorted, required, dataset)

    for (name, data) in [
        ("all", all_sorted),
        ("core", core_sorted),
        ("endpoint", endpoint_sorted),
    ]
        add_check!(
            dataset,
            "$name full-table row count",
            nrow(data) == 30_184,
            nrow(data),
            30_184,
        )
    end

    for (name, data) in [
        ("all", worst_all),
        ("core", worst_core),
        ("endpoint", worst_endpoint),
    ]
        add_check!(
            dataset,
            "$name worst-table row count",
            nrow(data) == 200,
            nrow(data),
            200,
        )
    end

    canonical_all = canonical_sorted_copy(
        all_sorted,
        legacy_keys,
    )
    canonical_core = canonical_sorted_copy(
        core_sorted,
        legacy_keys,
    )
    canonical_endpoint = canonical_sorted_copy(
        endpoint_sorted,
        legacy_keys,
    )

    add_check!(
        dataset,
        "three full sorted files contain identical rows",
        dataframe_exactly_equal(
            canonical_all,
            canonical_core,
        ) &&
        dataframe_exactly_equal(
            canonical_all,
            canonical_endpoint,
        ),
        (
            all_vs_core=dataframe_exactly_equal(
                canonical_all,
                canonical_core,
            ),
            all_vs_endpoint=dataframe_exactly_equal(
                canonical_all,
                canonical_endpoint,
            ),
        ),
        (all_vs_core=true, all_vs_endpoint=true),
    )

    add_check!(
        dataset,
        "worst blocks match corresponding full tables",
        dataframe_exactly_equal(
            first(all_sorted, 200),
            worst_all,
        ) &&
        dataframe_exactly_equal(
            first(core_sorted, 200),
            worst_core,
        ) &&
        dataframe_exactly_equal(
            first(endpoint_sorted, 200),
            worst_endpoint,
        ),
        (
            all=dataframe_exactly_equal(
                first(all_sorted, 200),
                worst_all,
            ),
            core=dataframe_exactly_equal(
                first(core_sorted, 200),
                worst_core,
            ),
            endpoint=dataframe_exactly_equal(
                first(endpoint_sorted, 200),
                worst_endpoint,
            ),
        ),
        "all true",
    )

    chunks = load_chunk_union(raw_directory, 59)

    add_check!(
        dataset,
        "checkpoint chunk total rows",
        nrow(chunks.data) == 30_184,
        nrow(chunks.data),
        30_184,
    )

    add_check!(
        dataset,
        "checkpoint chunks reproduce final rows",
        dataframe_exactly_equal(
            canonical_sorted_copy(chunks.data, legacy_keys),
            canonical_all,
        ),
        dataframe_exactly_equal(
            canonical_sorted_copy(chunks.data, legacy_keys),
            canonical_all,
        ),
        true,
    )

    numerical_validity =
        all(Int.(all_sorted.n_nonfinite_f) .== 0) &&
        all(Int.(all_sorted.n_nonfinite_g) .== 0) &&
        all(Int.(all_sorted.n_nonpositive_g) .== 0) &&
        all(Int.(all_sorted.n_nonfinite_m) .== 0) &&
        all(Bool.(all_sorted.mono_pass_all)) &&
        all(Bool.(all_sorted.mono_pass_core)) &&
        all(Bool.(all_sorted.mono_pass_endpoints))

    add_check!(
        dataset,
        "finite metrics, positive work, and monotonicity flags",
        numerical_validity,
        (
            nonfinite_f=sum(Int.(all_sorted.n_nonfinite_f)),
            nonfinite_g=sum(Int.(all_sorted.n_nonfinite_g)),
            nonpositive_g=sum(Int.(all_sorted.n_nonpositive_g)),
            nonfinite_m=sum(Int.(all_sorted.n_nonfinite_m)),
            mono_all=all(Bool.(all_sorted.mono_pass_all)),
            mono_core=all(Bool.(all_sorted.mono_pass_core)),
            mono_endpoints=all(
                Bool.(all_sorted.mono_pass_endpoints)
            ),
        ),
        (
            nonfinite_f=0,
            nonfinite_g=0,
            nonpositive_g=0,
            nonfinite_m=0,
            mono_all=true,
            mono_core=true,
            mono_endpoints=true,
        ),
    )

    actual_min_all = minimum(Float64.(all_sorted.min_diff_all))
    actual_min_core = minimum(Float64.(all_sorted.min_diff_core))
    actual_max_endpoint = maximum(
        Float64.(all_sorted.endpoint_cont_proxy)
    )

    add_check!(
        dataset,
        "reported padded-interval minimum reproduced",
        isapprox(
            actual_min_all,
            1.350445e-10;
            atol=1e-15,
            rtol=1e-5,
        ),
        actual_min_all,
        1.350445e-10,
    )

    add_check!(
        dataset,
        "reported core-interval minimum reproduced",
        isapprox(
            actual_min_core,
            3.11747e-10;
            atol=1e-15,
            rtol=1e-5,
        ),
        actual_min_core,
        3.11747e-10,
    )

    add_check!(
        dataset,
        "reported endpoint proxy maximum reproduced",
        isapprox(
            actual_max_endpoint,
            6.846899e-4;
            atol=1e-10,
            rtol=1e-5,
        ),
        actual_max_endpoint,
        6.846899e-4,
    )

    processed = renamed_legacy_copy(canonical_all)
    sort!(processed, [:p01, :rho, :kappa, :beta])

    processed_worst_all = renamed_legacy_copy(worst_all)
    processed_worst_core = renamed_legacy_copy(worst_core)
    processed_worst_endpoint = renamed_legacy_copy(worst_endpoint)

    output_full = joinpath(
        processed_directory,
        "pcli2_broad_all_results_p01.csv",
    )
    output_worst_all = joinpath(
        processed_directory,
        "pcli2_broad_worst_200_monotonicity_p01.csv",
    )
    output_worst_core = joinpath(
        processed_directory,
        "pcli2_broad_worst_200_core_p01.csv",
    )
    output_worst_endpoint = joinpath(
        processed_directory,
        "pcli2_broad_worst_200_endpoint_proxy_p01.csv",
    )

    atomic_csv_write(output_full, processed)
    atomic_csv_write(output_worst_all, processed_worst_all)
    atomic_csv_write(output_worst_core, processed_worst_core)
    atomic_csv_write(
        output_worst_endpoint,
        processed_worst_endpoint,
    )

    add_summary!(
        dataset;
        source=raw_directory,
        output=output_full,
        rows=nrow(processed),
        columns=ncol(processed),
        note=(
            "One canonical parameter-sorted processed table; the raw " *
            "directory retains all three original orderings and chunks."
        ),
    )

    return (
        raw=all_sorted,
        processed=processed,
        min_all=actual_min_all,
        min_core=actual_min_core,
        max_endpoint=actual_max_endpoint,
        output=output_full,
    )
end


function write_broad_extrema_summary(
    pcli1_result,
    pcli2_result,
    boundary_check::DataFrame,
    processed_directory::AbstractString,
)
    boundary_row = boundary_check[1, :]

    extrema = DataFrame([
        (
            experiment="broad PCLI1",
            metric="minimum g(x,z)-(1-beta)",
            value=Float64(pcli1_result.minimum),
            location_scope="30,184 parameter tuples",
        ),
        (
            experiment="broad PCLI2",
            metric="minimum forward difference, padded interval",
            value=Float64(pcli2_result.min_all),
            location_scope="30,184 parameter tuples",
        ),
        (
            experiment="broad PCLI2",
            metric="minimum forward difference, core interval",
            value=Float64(pcli2_result.min_core),
            location_scope="30,184 parameter tuples",
        ),
        (
            experiment="broad PCLI2",
            metric="maximum endpoint-continuity proxy",
            value=Float64(pcli2_result.max_endpoint),
            location_scope="30,184 parameter tuples",
        ),
        (
            experiment="boundary stress",
            metric="refined minimum PCLI1 slack",
            value=Float64(
                boundary_row.refined_minimum_pcli1_slack
            ),
            location_scope="20 refined worst coarse tuples",
        ),
        (
            experiment="boundary stress",
            metric="refined minimum PCLI2 core secant slope",
            value=Float64(
                boundary_row.refined_minimum_pcli2_core_slope
            ),
            location_scope="20 refined worst coarse tuples",
        ),
        (
            experiment="boundary stress",
            metric="refined minimum PCLI2 padded secant slope",
            value=Float64(
                boundary_row.refined_minimum_pcli2_all_slope
            ),
            location_scope="20 refined worst coarse tuples",
        ),
    ])

    output = joinpath(
        processed_directory,
        "pcli_numerical_extrema_summary.csv",
    )
    atomic_csv_write(output, extrema)
    return output
end


# ---------------------------------------------------------------------------
# Representative and supporting diagnostics
# ---------------------------------------------------------------------------

function validate_supporting_diagnostics(
    supporting_directory::AbstractString,
)
    dataset = "supporting_policy_diagnostics"

    paths = Dict(
        :capacity => joinpath(
            supporting_directory,
            "representative_T700_n10000_capacity_v1.csv",
        ),
        :metadata => joinpath(
            supporting_directory,
            "representative_T700_n10000_metadata_v1.csv",
        ),
        :report => joinpath(
            supporting_directory,
            "representative_T700_n10000_report_v1.csv",
        ),
        :rewards => joinpath(
            supporting_directory,
            "representative_T700_n10000_rewards_v1.csv",
        ),
        :pairwise => joinpath(
            supporting_directory,
            "representative_T700_n10000_top3_pairwise_v1.csv",
        ),
        :horizon => joinpath(
            supporting_directory,
            "seven_policy_horizon_sensitivity_v1.csv",
        ),
        :scaling => joinpath(
            supporting_directory,
            "seven_policy_scaling_timing_T700_n100_v1.csv",
        ),
    )

    for path in values(paths)
        require_file(path)
    end

    metadata = CSV.read(paths[:metadata], DataFrame)
    report = CSV.read(paths[:report], DataFrame)
    rewards = CSV.read(paths[:rewards], DataFrame)
    capacity = CSV.read(paths[:capacity], DataFrame)
    pairwise = CSV.read(paths[:pairwise], DataFrame)
    horizon = CSV.read(paths[:horizon], DataFrame)
    scaling = CSV.read(paths[:scaling], DataFrame)

    add_check!(
        dataset,
        "representative metadata row count",
        nrow(metadata) == 1,
        nrow(metadata),
        1,
    )

    if nrow(metadata) == 1
        metadata_names = Set(propertynames(metadata))

        if :T in metadata_names && :nruns in metadata_names
            add_check!(
                dataset,
                "representative design constants",
                Int(metadata.T[1]) == 700 &&
                Int(metadata.nruns[1]) == 10_000,
                (
                    T=Int(metadata.T[1]),
                    nruns=Int(metadata.nruns[1]),
                ),
                (T=700, nruns=10_000),
            )
        end
    end

    add_check!(
        dataset,
        "representative replication rows",
        nrow(rewards) == 10_000,
        nrow(rewards),
        10_000,
    )

    add_check!(
        dataset,
        "representative report/capacity alignment",
        nrow(report) == nrow(capacity) &&
        nrow(report) >= 4,
        (
            report_rows=nrow(report),
            capacity_rows=nrow(capacity),
        ),
        "equal and at least four policies",
    )

    add_check!(
        dataset,
        "representative pairwise rows",
        nrow(pairwise) == 3,
        nrow(pairwise),
        3,
    )

    add_check!(
        dataset,
        "supporting CSVs contain finite numerical entries",
        all(
            data -> all(
                column ->
                    !(eltype(column) <: Union{Missing, Number}) ||
                    all_finite(column),
                eachcol(data),
            ),
            [
                report,
                rewards,
                capacity,
                pairwise,
                horizon,
                scaling,
            ],
        ),
        true,
        true,
        note=(
            "Missing values are permitted where a comparison is undefined."
        ),
    )

    add_summary!(
        dataset;
        source=supporting_directory,
        output=supporting_directory,
        rows=nrow(rewards),
        columns=ncol(rewards),
        note=(
            "Representative replication-level rewards and smaller " *
            "horizon/scaling diagnostics are retained as supporting data."
        ),
    )

    return nothing
end


# ---------------------------------------------------------------------------
# Environment consistency
# ---------------------------------------------------------------------------

function validate_environment(
    repo::AbstractString,
    provenance_directory::AbstractString,
)
    dataset = "julia_environment"

    active_project = Base.active_project()
    expected_project = normpath(joinpath(repo, "Project.toml"))

    add_check!(
        dataset,
        "active project",
        active_project !== nothing &&
        normpath(active_project) == expected_project,
        active_project,
        expected_project,
    )

    root_project = require_file(
        joinpath(repo, "Project.toml")
    )
    root_manifest = require_file(
        joinpath(repo, "Manifest.toml")
    )

    captured_project = require_file(
        joinpath(provenance_directory, "Project_used.toml")
    )
    captured_manifest = require_file(
        joinpath(provenance_directory, "Manifest_used.toml")
    )

    add_check!(
        dataset,
        "Project.toml matches captured environment",
        sha256_hex(root_project) == sha256_hex(captured_project),
        sha256_hex(root_project),
        sha256_hex(captured_project),
    )

    add_check!(
        dataset,
        "Manifest.toml matches captured environment",
        sha256_hex(root_manifest) == sha256_hex(captured_manifest),
        sha256_hex(root_manifest),
        sha256_hex(captured_manifest),
    )

    add_check!(
        dataset,
        "Julia major/minor compatibility",
        VERSION >= v"1.12.0" && VERSION < v"1.13.0",
        VERSION,
        "1.12.x",
    )

    return nothing
end


# ---------------------------------------------------------------------------
# Output manifests and main program
# ---------------------------------------------------------------------------

function write_output_manifest(
    directories::AbstractVector{String},
    manifest_path::AbstractString,
)
    files = String[]

    for directory in directories
        append!(files, list_files_recursively(directory))
    end

    unique!(files)
    sort!(files)

    filter!(
        path -> normpath(path) != normpath(manifest_path),
        files,
    )

    common_root = dirname(dirname(manifest_path))

    rows = DataFrame(
        relative_path=String[],
        size_bytes=Int64[],
        sha256=String[],
    )

    for path in files
        relative = relpath(path, common_root)
        push!(
            rows,
            (
                relative_path=replace(relative, "\\" => "/"),
                size_bytes=filesize(path),
                sha256=sha256_hex(path),
            ),
        )
    end

    atomic_csv_write(manifest_path, rows)
    return rows
end


function main()
    repo = resolve_repo_root()

    reproducibility = require_directory(
        joinpath(repo, "reproducibility")
    )

    raw = require_directory(
        joinpath(reproducibility, "data", "raw")
    )

    supporting = require_directory(
        joinpath(reproducibility, "data", "supporting")
    )

    processed = joinpath(
        reproducibility,
        "data",
        "processed",
    )

    checks = joinpath(
        reproducibility,
        "data",
        "checks",
    )

    curation_provenance = joinpath(
        reproducibility,
        "provenance",
        "curation_v1",
    )

    environment_provenance = require_directory(
        joinpath(
            reproducibility,
            "provenance",
            "julia_environment_used",
        )
    )

    mkpath(processed)
    mkpath(checks)
    mkpath(curation_provenance)

    println()
    println("=== paperPCLsensingErrors result curation v1 ===")
    println("Repository: ", repo)
    println("Julia:      ", VERSION)
    println("Threads:    ", Threads.nthreads())
    println()

    validate_environment(repo, environment_provenance)

    curate_four_policy_grid(
        require_directory(
            joinpath(raw, "four_policy_grid")
        ),
        processed,
    )

    curate_homogeneous_ties(
        require_file(
            joinpath(
                raw,
                "homogeneous_ties",
                "homogeneous_tie_grid_T700_n1000_v2.csv",
            )
        ),
        processed,
    )

    boundary_check = validate_boundary_stress(
        require_directory(
            joinpath(raw, "pcli_boundary_stress")
        ),
        checks,
    )

    pcli1_result = curate_broad_pcli1(
        require_directory(
            joinpath(raw, "pcli_broad", "pcli1")
        ),
        processed,
    )

    pcli2_result = curate_broad_pcli2(
        require_directory(
            joinpath(raw, "pcli_broad", "pcli2")
        ),
        processed,
    )

    extrema_output = write_broad_extrema_summary(
        pcli1_result,
        pcli2_result,
        boundary_check,
        processed,
    )

    validate_supporting_diagnostics(
        require_directory(
            joinpath(
                supporting,
                "pilot_diagnostics",
            )
        )
    )

    checks_frame = DataFrame(CHECK_ROWS)
    sort!(checks_frame, [:dataset, :check])

    checks_output = joinpath(
        checks,
        "all_experiment_checks_v1.csv",
    )
    atomic_csv_write(checks_output, checks_frame)

    summary_frame = DataFrame(SUMMARY_ROWS)
    sort!(summary_frame, :dataset)

    summary_output = joinpath(
        checks,
        "all_experiment_summary_v1.csv",
    )
    atomic_csv_write(summary_output, summary_frame)

    all_pass = all(checks_frame.status .== "PASS")
    failed = checks_frame[checks_frame.status .== "FAIL", :]

    run_info = """
paperPCLsensingErrors result curation v1
Generated: $(Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
Repository: $repo
Active project: $(Base.active_project())
Julia version: $VERSION
Julia threads: $(Threads.nthreads())
BLAS threads: $(LinearAlgebra.BLAS.get_num_threads())
Checks: $(nrow(checks_frame))
Passed: $(count(==("PASS"), checks_frame.status))
Failed: $(count(==("FAIL"), checks_frame.status))
All checks passed: $all_pass

Raw inputs were not modified.
No simulation or PCLI grid was rerun.
No Git operation was performed.

Processed extrema summary:
$extrema_output
"""

    # LinearAlgebra is loaded lazily here to avoid changing the computational
    # routines; it is a standard library and this call is metadata only.
    atomic_text_write(
        joinpath(curation_provenance, "curation_run_info.txt"),
        run_info,
    )

    manifest_path = joinpath(
        curation_provenance,
        "curated_outputs_sha256.csv",
    )

    output_manifest = write_output_manifest(
        [processed, checks, curation_provenance],
        manifest_path,
    )

    println("Checks written to:")
    println("  ", checks_output)
    println("  ", summary_output)
    println("Processed data written to:")
    println("  ", processed)
    println("Curation manifest:")
    println("  ", manifest_path)
    println()
    println(
        "Checks passed: ",
        count(==("PASS"), checks_frame.status),
        "/",
        nrow(checks_frame),
    )
    println("Manifest entries: ", nrow(output_manifest))

    if !all_pass
        println()
        println("Failed checks:")
        show(stdout, MIME("text/plain"), failed)
        println()
        error("One or more result-curation checks failed.")
    end

    println()
    println("All result-curation checks passed.")
    println("No Git operation was performed.")

    return (
        checks=checks_frame,
        summary=summary_frame,
        manifest=output_manifest,
        processed_directory=processed,
        checks_directory=checks,
        provenance_directory=curation_provenance,
    )
end


# LinearAlgebra is a Julia standard library and is needed only for the
# recorded BLAS-thread count in curation_run_info.txt.
using LinearAlgebra

main()
