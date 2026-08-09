module HomogeneousTieGridRkappaV2

using Random
using Statistics
using Distributions
using DataFrames
using CSV

using ..SensingErrorBenchmarkIndices:
    BSFProjectType,
    lookup_priority

using ..SevenPolicyPilotRkappa:
    build_mp_tables

export HOMOGENEOUS_TIE_N_VALUES,
       HOMOGENEOUS_TIE_ALPHA_VALUES,
       homogeneous_tie_profiles,
       homogeneous_tie_manifest,
       homogeneous_tie_case_id,
       lexicographic_tie_selfcheck,
       simulate_homogeneous_tie_case,
       run_homogeneous_tie_grid,
       validate_homogeneous_tie_output


const HOMOGENEOUS_TIE_N_VALUES = [100, 400, 1600]

const HOMOGENEOUS_TIE_ALPHA_VALUES = [
    0.05,
    0.10,
    0.15,
    0.20,
    0.25,
    0.30,
    0.40,
    0.50
]

const _POLICY_ORDER = (
    :mp_belief_random,
    :belief_fixed,
    :belief_cyclic,
    :belief_random
)

const _POLICY_LABELS = Dict(
    :mp_belief_random =>
        "MP, belief secondary key and randomized exact ties",
    :belief_fixed => "Belief/myopic, fixed-label ties",
    :belief_cyclic => "Belief/myopic, cyclic ties",
    :belief_random => "Belief/myopic, randomized ties"
)

const _MP_BELIEF_RANDOM = 1
const _BELIEF_FIXED = 2
const _BELIEF_CYCLIC = 3
const _BELIEF_RANDOM = 4
const _NPOLICIES = length(_POLICY_ORDER)

const _RUNNER_REVISION =
    "2026-08-05-homogeneous-tie-grid-lexicographic-random-v2"


"""
Return the seven homogeneous parameter profiles already used as the four
type-A and three type-B profiles in the heterogeneous paper experiment.
"""
function homogeneous_tie_profiles(; beta::Real=0.99)
    betaf = Float64(beta)

    specifications = [
        (
            name="A_very_selfhealing",
            family="A",
            p01=0.01,
            rho=0.90,
            kappa=0.70,
            r=1.0
        ),
        (
            name="A_mild_selfhealing",
            family="A",
            p01=0.03,
            rho=0.80,
            kappa=0.70,
            r=1.0
        ),
        (
            name="A_balanced",
            family="A",
            p01=0.05,
            rho=0.70,
            kappa=0.70,
            r=1.0
        ),
        (
            name="A_harder_obs",
            family="A",
            p01=0.02,
            rho=0.85,
            kappa=0.55,
            r=1.0
        ),
        (
            name="B_fragile",
            family="B",
            p01=0.10,
            rho=0.10,
            kappa=0.95,
            r=1.0
        ),
        (
            name="B_very_fragile",
            family="B",
            p01=0.15,
            rho=0.05,
            kappa=0.95,
            r=1.0
        ),
        (
            name="B_persistent_bad",
            family="B",
            p01=0.08,
            rho=0.20,
            kappa=0.95,
            r=1.0
        )
    ]

    return [
        merge(
            specification,
            (
                project_type=BSFProjectType(
                    p01=specification.p01,
                    rho=specification.rho,
                    kappa=specification.kappa,
                    r=specification.r,
                    beta=betaf
                ),
            )
        )
        for specification in specifications
    ]
end


function homogeneous_tie_manifest(; beta::Real=0.99)
    profiles = homogeneous_tie_profiles(; beta=beta)

    return DataFrame([
        (
            profile_index=profile_index,
            profile=profile.name,
            family=profile.family,
            p01=profile.p01,
            rho=profile.rho,
            kappa=profile.kappa,
            reward=profile.r,
            beta=Float64(beta),
            cases_per_profile=
                length(HOMOGENEOUS_TIE_ALPHA_VALUES) *
                length(HOMOGENEOUS_TIE_N_VALUES)
        )
        for (profile_index, profile) in enumerate(profiles)
    ])
end


function homogeneous_tie_case_id(
    profile_index::Integer,
    alpha_index::Integer,
    N_index::Integer
)
    1 <= profile_index <= 7 ||
        throw(ArgumentError("profile_index must lie in 1:7."))
    1 <= alpha_index <= length(HOMOGENEOUS_TIE_ALPHA_VALUES) ||
        throw(ArgumentError("alpha_index is outside the paper grid."))
    1 <= N_index <= length(HOMOGENEOUS_TIE_N_VALUES) ||
        throw(ArgumentError("N_index is outside the paper grid."))

    return (
        ((Int(profile_index) - 1) *
         length(HOMOGENEOUS_TIE_ALPHA_VALUES) +
         (Int(alpha_index) - 1)) *
        length(HOMOGENEOUS_TIE_N_VALUES) +
        Int(N_index)
    )
end


function _atomic_csv_write(path::AbstractString, data::DataFrame)
    temporary_file = String(path) * ".tmp"
    CSV.write(temporary_file, data)
    mv(temporary_file, path; force=true)
    return path
end


@inline function _phi0(x::Float64, project_type)
    return project_type.p01 + project_type.rho * x
end


@inline function _phi1(x::Float64, project_type)
    return project_type.p01 +
           project_type.rho *
           (1.0 - project_type.kappa) * x /
           (1.0 - project_type.kappa * x)
end


function _fill_mp_priorities!(priorities, beliefs, mp_table)
    @inbounds for i in eachindex(beliefs)
        priorities[i] = lookup_priority(mp_table, beliefs[i])
    end
    return priorities
end


function _fill_fixed_ranks!(ranks::Vector{Int})
    @inbounds for i in eachindex(ranks)
        ranks[i] = i
    end
    return ranks
end


function _fill_cyclic_ranks!(
    ranks::Vector{Int},
    period::Integer
)
    N = length(ranks)
    shift = mod(Int(period) - 1, N)

    @inbounds for i in eachindex(ranks)
        ranks[i] = mod(i - 1 - shift, N) + 1
    end

    return ranks
end


function _select_ranked!(
    actions::BitVector,
    order::Vector{Int},
    scores::Vector{Float64},
    M::Int,
    tie_ranks::Vector{Int}
)
    all(isfinite, scores) ||
        error("A nonfinite ranking score was encountered.")

    sort!(
        order;
        alg=Base.Sort.MergeSort,
        lt=(i, j) ->
            scores[i] > scores[j] ||
            (scores[i] == scores[j] && tie_ranks[i] < tie_ranks[j])
    )

    fill!(actions, false)

    @inbounds for position in 1:M
        actions[order[position]] = true
    end

    cutoff_score = scores[order[M]]
    strictly_above = 0
    cutoff_class_size = 0

    @inbounds for score in scores
        if score > cutoff_score
            strictly_above += 1
        elseif score == cutoff_score
            cutoff_class_size += 1
        end
    end

    tie_straddles_cutoff =
        strictly_above < M &&
        M < strictly_above + cutoff_class_size

    ambiguous_activations =
        tie_straddles_cutoff ? M - strictly_above : 0

    return (
        tie_straddles_cutoff=tie_straddles_cutoff,
        cutoff_class_size=cutoff_class_size,
        ambiguous_activations=ambiguous_activations
    )
end


function _select_random_ties!(
    actions::BitVector,
    order::Vector{Int},
    scores::Vector{Float64},
    M::Int,
    random_keys::Vector{Float64}
)
    all(isfinite, scores) && all(isfinite, random_keys) ||
        error("A nonfinite ranking score or random tie key was encountered.")

    sort!(
        order;
        alg=Base.Sort.MergeSort,
        lt=(i, j) ->
            scores[i] > scores[j] ||
            (
                scores[i] == scores[j] &&
                (
                    random_keys[i] < random_keys[j] ||
                    (random_keys[i] == random_keys[j] && i < j)
                )
            )
    )

    fill!(actions, false)

    @inbounds for position in 1:M
        actions[order[position]] = true
    end

    cutoff_score = scores[order[M]]
    strictly_above = 0
    cutoff_class_size = 0

    @inbounds for score in scores
        if score > cutoff_score
            strictly_above += 1
        elseif score == cutoff_score
            cutoff_class_size += 1
        end
    end

    tie_straddles_cutoff =
        strictly_above < M &&
        M < strictly_above + cutoff_class_size

    ambiguous_activations =
        tie_straddles_cutoff ? M - strictly_above : 0

    return (
        tie_straddles_cutoff=tie_straddles_cutoff,
        cutoff_class_size=cutoff_class_size,
        ambiguous_activations=ambiguous_activations
    )
end


"""
Rank lexicographically by tabulated MP priority, then by belief, and use the
random key only when both numerical keys are exactly equal.  The belief key
repairs floating-point collisions between the interpolated MP priorities of
distinct beliefs.  Returned tie statistics describe only genuine equal-belief
ties that straddle the activation cutoff.
"""
function _select_mp_belief_random!(
    actions::BitVector,
    order::Vector{Int},
    priorities::Vector{Float64},
    beliefs::Vector{Float64},
    M::Int,
    random_keys::Vector{Float64}
)
    all(isfinite, priorities) &&
    all(isfinite, beliefs) &&
    all(isfinite, random_keys) ||
        error("A nonfinite MP priority, belief, or random tie key was encountered.")

    sort!(
        order;
        alg=Base.Sort.MergeSort,
        lt=(i, j) ->
            priorities[i] > priorities[j] ||
            (
                priorities[i] == priorities[j] &&
                (
                    beliefs[i] > beliefs[j] ||
                    (
                        beliefs[i] == beliefs[j] &&
                        (
                            random_keys[i] < random_keys[j] ||
                            (random_keys[i] == random_keys[j] && i < j)
                        )
                    )
                )
            )
    )

    fill!(actions, false)

    @inbounds for position in 1:M
        actions[order[position]] = true
    end

    cutoff_priority = priorities[order[M]]
    cutoff_belief = beliefs[order[M]]
    strictly_above = 0
    cutoff_class_size = 0

    @inbounds for i in eachindex(priorities, beliefs)
        if priorities[i] > cutoff_priority ||
           (
               priorities[i] == cutoff_priority &&
               beliefs[i] > cutoff_belief
           )
            strictly_above += 1
        elseif priorities[i] == cutoff_priority &&
               beliefs[i] == cutoff_belief
            cutoff_class_size += 1
        end
    end

    tie_straddles_cutoff =
        strictly_above < M &&
        M < strictly_above + cutoff_class_size

    ambiguous_activations =
        tie_straddles_cutoff ? M - strictly_above : 0

    return (
        tie_straddles_cutoff=tie_straddles_cutoff,
        cutoff_class_size=cutoff_class_size,
        ambiguous_activations=ambiguous_activations
    )
end


"""
Check on a synthetic priority collision that belief precedes the random key
and that the MP and belief selectors use the same randomization for a genuine
equal-belief tie.
"""
function lexicographic_tie_selfcheck()
    priorities = [1.0, 1.0, 1.0, 0.2]
    beliefs = [0.2, 0.8, 0.8, 0.1]
    random_keys = [0.01, 0.90, 0.10, 0.001]
    mp_actions = falses(4)
    belief_actions = falses(4)

    statistics = _select_mp_belief_random!(
        mp_actions,
        collect(1:4),
        priorities,
        beliefs,
        1,
        random_keys
    )
    _select_random_ties!(
        belief_actions,
        collect(1:4),
        beliefs,
        1,
        random_keys
    )

    checks = (
        mp_actions == belief_actions,
        mp_actions[3],
        !mp_actions[1],
        statistics.tie_straddles_cutoff,
        statistics.cutoff_class_size == 2,
        statistics.ambiguous_activations == 1
    )

    all(checks) ||
        error("The MP--belief lexicographic tie-breaking self-check failed.")

    return true
end


function _update_policy!(
    beliefs::Vector{Float64},
    actions::BitVector,
    ack_uniforms::Vector{Float64},
    project_type
)
    reward = 0.0
    p11 = project_type.p01 + project_type.rho

    @inbounds for i in eachindex(beliefs)
        x = beliefs[i]

        if actions[i]
            if ack_uniforms[i] < project_type.kappa * x
                reward += project_type.r
                beliefs[i] = p11
            else
                beliefs[i] = _phi1(x, project_type)
            end
        else
            beliefs[i] = _phi0(x, project_type)
        end
    end

    return reward
end


function _record_tie_statistics!(
    tie_events::Matrix{Int},
    postinitial_tie_events::Matrix{Int},
    ambiguous_activations::Matrix{Int},
    cutoff_class_sum::Matrix{Int},
    cutoff_class_maximum::Matrix{Int},
    run_index::Int,
    policy_index::Int,
    period::Int,
    statistics
)
    if statistics.tie_straddles_cutoff
        tie_events[run_index, policy_index] += 1
        ambiguous_activations[run_index, policy_index] +=
            statistics.ambiguous_activations
        cutoff_class_sum[run_index, policy_index] +=
            statistics.cutoff_class_size
        cutoff_class_maximum[run_index, policy_index] = max(
            cutoff_class_maximum[run_index, policy_index],
            statistics.cutoff_class_size
        )

        if period > 1
            postinitial_tie_events[run_index, policy_index] += 1
        end
    end

    return nothing
end


"""
Simulate one homogeneous instance under four implementations:

1. MP ranking with belief as a secondary numerical key and randomized exact
   equal-belief ties;
2. belief/myopic ranking with fixed-label ties;
3. belief/myopic ranking with a cyclic tie order; and
4. belief/myopic ranking with fresh randomized tie keys.

All implementations use exactly M activations and common ACK uniforms.  The
first and fourth columns use the same random tie keys and provide a direct
sample-path check of the homogeneous MP--myopic ranking-equivalence claim.
Cutoff-tie statistics are reported both
including and excluding period 1, when the common initial belief forces a tie.
"""
function simulate_homogeneous_tie_case(
    project_type,
    mp_table,
    N::Integer,
    M::Integer;
    x_initial::Real=0.5,
    T::Integer=700,
    nruns::Integer=1_000,
    conf_level::Real=0.95,
    seed::Integer=20260820,
    threaded::Bool=true
)
    Ni = Int(N)
    Mi = Int(M)
    Ti = Int(T)
    nrunsi = Int(nruns)
    x0 = Float64(x_initial)

    Ni >= 2 || throw(ArgumentError("N must be at least 2."))
    1 <= Mi < Ni || throw(ArgumentError("Require 1 <= M < N."))
    Ti >= 1 || throw(ArgumentError("T must be positive."))
    nrunsi >= 2 || throw(ArgumentError("nruns must be at least 2."))
    0.0 <= x0 <= 1.0 ||
        throw(ArgumentError("x_initial must lie in [0,1]."))
    0.0 < conf_level < 1.0 ||
        throw(ArgumentError("conf_level must lie in (0,1)."))

    master_rng = MersenneTwister(seed)
    ack_seeds = rand(master_rng, UInt64, nrunsi)
    tie_seeds = rand(master_rng, UInt64, nrunsi)

    discount_factors = [project_type.beta^t for t in 0:(Ti - 1)]
    raw_discounted_rewards = zeros(Float64, nrunsi, _NPOLICIES)
    tie_events = zeros(Int, nrunsi, _NPOLICIES)
    postinitial_tie_events = zeros(Int, nrunsi, _NPOLICIES)
    ambiguous_activations = zeros(Int, nrunsi, _NPOLICIES)
    cutoff_class_sum = zeros(Int, nrunsi, _NPOLICIES)
    cutoff_class_maximum = zeros(Int, nrunsi, _NPOLICIES)
    activation_cv = zeros(Float64, nrunsi, _NPOLICIES)
    mp_random_action_mismatch_periods = zeros(Int, nrunsi)

    function simulate_one_run!(run_index::Int)
        ack_rng = MersenneTwister(ack_seeds[run_index])
        tie_rng = MersenneTwister(tie_seeds[run_index])

        beliefs = [fill(x0, Ni) for _ in 1:_NPOLICIES]
        actions = [falses(Ni) for _ in 1:_NPOLICIES]
        orders = [collect(1:Ni) for _ in 1:_NPOLICIES]
        scores = [zeros(Float64, Ni) for _ in 1:_NPOLICIES]
        tie_ranks = [collect(1:Ni) for _ in 1:_NPOLICIES]
        random_keys = zeros(Float64, Ni)
        ack_uniforms = zeros(Float64, Ni)
        rewards = zeros(Float64, _NPOLICIES)
        activation_counts = [zeros(Int, Ni) for _ in 1:_NPOLICIES]

        for period in 1:Ti
            rand!(ack_rng, ack_uniforms)
            rand!(tie_rng, random_keys)

            _fill_mp_priorities!(
                scores[_MP_BELIEF_RANDOM],
                beliefs[_MP_BELIEF_RANDOM],
                mp_table
            )
            mp_statistics = _select_mp_belief_random!(
                actions[_MP_BELIEF_RANDOM],
                orders[_MP_BELIEF_RANDOM],
                scores[_MP_BELIEF_RANDOM],
                beliefs[_MP_BELIEF_RANDOM],
                Mi,
                random_keys
            )

            scores[_BELIEF_FIXED] .= beliefs[_BELIEF_FIXED]
            _fill_fixed_ranks!(tie_ranks[_BELIEF_FIXED])
            fixed_statistics = _select_ranked!(
                actions[_BELIEF_FIXED],
                orders[_BELIEF_FIXED],
                scores[_BELIEF_FIXED],
                Mi,
                tie_ranks[_BELIEF_FIXED]
            )

            scores[_BELIEF_CYCLIC] .= beliefs[_BELIEF_CYCLIC]
            _fill_cyclic_ranks!(tie_ranks[_BELIEF_CYCLIC], period)
            cyclic_statistics = _select_ranked!(
                actions[_BELIEF_CYCLIC],
                orders[_BELIEF_CYCLIC],
                scores[_BELIEF_CYCLIC],
                Mi,
                tie_ranks[_BELIEF_CYCLIC]
            )

            scores[_BELIEF_RANDOM] .= beliefs[_BELIEF_RANDOM]
            random_statistics = _select_random_ties!(
                actions[_BELIEF_RANDOM],
                orders[_BELIEF_RANDOM],
                scores[_BELIEF_RANDOM],
                Mi,
                random_keys
            )

            _record_tie_statistics!(
                tie_events,
                postinitial_tie_events,
                ambiguous_activations,
                cutoff_class_sum,
                cutoff_class_maximum,
                run_index,
                _MP_BELIEF_RANDOM,
                period,
                mp_statistics
            )
            _record_tie_statistics!(
                tie_events,
                postinitial_tie_events,
                ambiguous_activations,
                cutoff_class_sum,
                cutoff_class_maximum,
                run_index,
                _BELIEF_FIXED,
                period,
                fixed_statistics
            )
            _record_tie_statistics!(
                tie_events,
                postinitial_tie_events,
                ambiguous_activations,
                cutoff_class_sum,
                cutoff_class_maximum,
                run_index,
                _BELIEF_CYCLIC,
                period,
                cyclic_statistics
            )
            _record_tie_statistics!(
                tie_events,
                postinitial_tie_events,
                ambiguous_activations,
                cutoff_class_sum,
                cutoff_class_maximum,
                run_index,
                _BELIEF_RANDOM,
                period,
                random_statistics
            )

            if actions[_MP_BELIEF_RANDOM] != actions[_BELIEF_RANDOM]
                mp_random_action_mismatch_periods[run_index] += 1
            end

            for policy_index in 1:_NPOLICIES
                @inbounds for i in 1:Ni
                    activation_counts[policy_index][i] +=
                        actions[policy_index][i]
                end

                period_reward = _update_policy!(
                    beliefs[policy_index],
                    actions[policy_index],
                    ack_uniforms,
                    project_type
                )

                rewards[policy_index] +=
                    discount_factors[period] * period_reward
            end
        end

        raw_discounted_rewards[run_index, :] .= rewards

        for policy_index in 1:_NPOLICIES
            counts = activation_counts[policy_index]
            activation_cv[run_index, policy_index] =
                std(counts; corrected=false) / mean(counts)
        end

        return nothing
    end

    start_time = time_ns()

    if threaded && Threads.nthreads() > 1
        Threads.@threads :static for run_index in 1:nrunsi
            simulate_one_run!(run_index)
        end
    else
        for run_index in 1:nrunsi
            simulate_one_run!(run_index)
        end
    end

    elapsed_seconds = (time_ns() - start_time) / 1e9
    normalization = (1.0 - project_type.beta) / Ni
    normalized_rewards = normalization .* raw_discounted_rewards
    tcrit = quantile(TDist(nrunsi - 1), 0.975)
    reference = view(normalized_rewards, :, _BELIEF_RANDOM)

    table_minimum = minimum(mp_table.values)
    table_minimum_difference = minimum(diff(mp_table.values))
    mismatch_periods = sum(mp_random_action_mismatch_periods)
    mp_reward_difference =
        view(normalized_rewards, :, _MP_BELIEF_RANDOM) .- reference

    rows = NamedTuple[]

    for policy_index in 1:_NPOLICIES
        policy = _POLICY_ORDER[policy_index]
        samples = view(normalized_rewards, :, policy_index)
        sample_mean = mean(samples)
        sample_stderr = std(samples) / sqrt(nrunsi)
        differences = samples .- reference
        paired_mean = mean(differences)
        paired_stderr = std(differences) / sqrt(nrunsi)

        total_tie_events = sum(view(tie_events, :, policy_index))
        total_postinitial_tie_events =
            sum(view(postinitial_tie_events, :, policy_index))
        total_ambiguous =
            sum(view(ambiguous_activations, :, policy_index))
        total_cutoff_class =
            sum(view(cutoff_class_sum, :, policy_index))

        mean_cutoff_class_conditional =
            total_tie_events == 0 ? 0.0 :
            total_cutoff_class / total_tie_events

        postinitial_slots = nrunsi * max(Ti - 1, 0)
        postinitial_fraction =
            postinitial_slots == 0 ? 0.0 :
            total_postinitial_tie_events / postinitial_slots

        push!(
            rows,
            (
                policy=String(policy),
                label=_POLICY_LABELS[policy],
                mean_reward=sample_mean,
                stderr=sample_stderr,
                ci_low=sample_mean - tcrit * sample_stderr,
                ci_high=sample_mean + tcrit * sample_stderr,
                paired_mean_vs_belief_random=paired_mean,
                paired_stderr_vs_belief_random=paired_stderr,
                paired_ci_low_vs_belief_random=
                    paired_mean - tcrit * paired_stderr,
                paired_ci_high_vs_belief_random=
                    paired_mean + tcrit * paired_stderr,
                relative_difference_vs_belief_random=
                    paired_mean / mean(reference),
                cutoff_tie_fraction=
                    total_tie_events / (nrunsi * Ti),
                cutoff_tie_fraction_excluding_initial=
                    postinitial_fraction,
                ambiguous_activation_fraction=
                    total_ambiguous / (nrunsi * Ti * Mi),
                mean_cutoff_class_size_conditional=
                    mean_cutoff_class_conditional,
                maximum_cutoff_class_size=
                    maximum(view(
                        cutoff_class_maximum,
                        :,
                        policy_index
                    )),
                mean_activation_count_cv=
                    mean(view(activation_cv, :, policy_index)),
                mp_random_action_mismatch_periods=mismatch_periods,
                mp_random_action_mismatch_fraction=
                    mismatch_periods / (nrunsi * Ti),
                mp_random_rewards_exact=
                    isequal(
                        view(normalized_rewards, :, _MP_BELIEF_RANDOM),
                        reference
                    ),
                mp_random_maximum_absolute_reward_difference=
                    maximum(abs.(mp_reward_difference)),
                mp_table_minimum=table_minimum,
                mp_table_minimum_adjacent_difference=
                    table_minimum_difference,
                mp_table_nonnegative=table_minimum >= -1e-12,
                mp_table_nondecreasing=
                    table_minimum_difference >= -1e-12
            )
        )
    end

    return (
        rows=DataFrame(rows),
        normalized_rewards=normalized_rewards,
        tie_events=tie_events,
        postinitial_tie_events=postinitial_tie_events,
        ambiguous_activations=ambiguous_activations,
        activation_cv=activation_cv,
        policies=collect(_POLICY_ORDER),
        N=Ni,
        M=Mi,
        T=Ti,
        nruns=nrunsi,
        beta=project_type.beta,
        seed=Int(seed),
        elapsed_seconds=elapsed_seconds,
        all_rewards_finite=all(isfinite, normalized_rewards),
        all_priorities_finite=all(isfinite, mp_table.values),
        exact_capacity_ok=true,
        mp_random_action_mismatch_periods=mismatch_periods,
        mp_random_rewards_exact=
            isequal(
                view(normalized_rewards, :, _MP_BELIEF_RANDOM),
                reference
            )
    )
end


function _requested_case_ids(
    profile_indices,
    alpha_indices,
    N_indices
)
    return Set(
        homogeneous_tie_case_id(
            profile_index,
            alpha_index,
            N_index
        )
        for profile_index in profile_indices,
            alpha_index in alpha_indices,
            N_index in N_indices
    )
end


function _validate_checkpoint(
    data::DataFrame;
    T::Integer,
    nruns::Integer,
    beta::Real,
    base_seed::Integer
)
    nrow(data) == 0 && return Set{Int}()

    required_columns = Set([
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
        :cutoff_tie_fraction,
        :cutoff_tie_fraction_excluding_initial,
        :mp_random_action_mismatch_periods,
        :mp_random_rewards_exact,
        :mp_table_nonnegative,
        :mp_table_nondecreasing,
        :all_rewards_finite,
        :all_priorities_finite,
        :exact_capacity_ok
    ])

    missing_columns = setdiff(required_columns, Set(propertynames(data)))
    isempty(missing_columns) ||
        error("Checkpoint is missing columns: $(collect(missing_columns)).")

    expected_policies = Set(string.(collect(_POLICY_ORDER)))
    completed_case_ids = Set{Int}()

    for group in groupby(data, :case_id)
        case_id = Int(first(group.case_id))

        nrow(group) == _NPOLICIES ||
            error("Checkpoint has an incomplete case_id=$case_id.")
        Set(String.(group.policy)) == expected_policies ||
            error("Checkpoint has the wrong policies for case_id=$case_id.")
        nrow(unique(select(group, :policy))) == _NPOLICIES ||
            error("Checkpoint duplicates a policy for case_id=$case_id.")

        profile_index = Int(first(group.profile_index))
        alpha_index = Int(first(group.alpha_index))
        N_index = Int(first(group.N_index))
        expected_case_id = homogeneous_tie_case_id(
            profile_index,
            alpha_index,
            N_index
        )

        case_id == expected_case_id ||
            error("Checkpoint case numbering is inconsistent at case_id=$case_id.")
        Int(first(group.N)) == HOMOGENEOUS_TIE_N_VALUES[N_index] ||
            error("Checkpoint N and N_index disagree at case_id=$case_id.")
        isapprox(
            Float64(first(group.alphaM_target)),
            HOMOGENEOUS_TIE_ALPHA_VALUES[alpha_index];
            atol=1e-14,
            rtol=0.0
        ) || error("Checkpoint capacity ratio is inconsistent at case_id=$case_id.")
        Int(first(group.M)) == round(
            Int,
            HOMOGENEOUS_TIE_ALPHA_VALUES[alpha_index] *
            HOMOGENEOUS_TIE_N_VALUES[N_index]
        ) || error("Checkpoint M is inconsistent at case_id=$case_id.")
        Int(first(group.T)) == Int(T) ||
            error("Checkpoint T is inconsistent at case_id=$case_id.")
        Int(first(group.nruns)) == Int(nruns) ||
            error("Checkpoint nruns is inconsistent at case_id=$case_id.")
        isapprox(
            Float64(first(group.beta)),
            Float64(beta);
            atol=0.0,
            rtol=1e-14
        ) || error("Checkpoint beta is inconsistent at case_id=$case_id.")
        Int(first(group.seed)) == Int(base_seed) + case_id ||
            error("Checkpoint seed is inconsistent at case_id=$case_id.")
        all(group.all_rewards_finite) ||
            error("Checkpoint records nonfinite rewards at case_id=$case_id.")
        all(group.all_priorities_finite) ||
            error("Checkpoint records nonfinite priorities at case_id=$case_id.")
        all(group.exact_capacity_ok) ||
            error("Checkpoint records a capacity failure at case_id=$case_id.")

        push!(completed_case_ids, case_id)
    end

    nrow(data) == _NPOLICIES * length(completed_case_ids) ||
        error("Checkpoint row count is inconsistent with completed cases.")

    return completed_case_ids
end


"""
Run the 168-case homogeneous tie diagnostic with atomic case-level
checkpointing.  The default design uses the seven paper profiles, all eight
capacity ratios, N in {100,400,1600}, T=700, and 1000 replications.

Use `max_new_cases=1` for the full-scale preflight.  Rerunning without that
limit resumes from the checkpoint and does not repeat completed cases.
"""
function run_homogeneous_tie_grid(
    ;
    mp_index_fn,
    profile_indices::AbstractVector{<:Integer}=collect(1:7),
    alpha_values::AbstractVector{<:Real}=
        HOMOGENEOUS_TIE_ALPHA_VALUES,
    N_values::AbstractVector{<:Integer}=
        HOMOGENEOUS_TIE_N_VALUES,
    beta::Real=0.99,
    x_initial::Real=0.5,
    T::Integer=700,
    nruns::Integer=1_000,
    table_nx::Integer=4001,
    base_seed::Integer=20260820,
    output_file::AbstractString=
        "homogeneous_tie_grid_T700_n1000_v2.csv",
    max_new_cases::Union{Nothing,Integer}=nothing,
    threaded::Bool=true
)
    lexicographic_tie_selfcheck()

    T >= 1 || throw(ArgumentError("T must be positive."))
    nruns >= 2 || throw(ArgumentError("nruns must be at least 2."))
    table_nx >= 2 || throw(ArgumentError("table_nx must be at least 2."))
    max_new_cases === nothing || max_new_cases >= 0 ||
        throw(ArgumentError("max_new_cases must be nonnegative."))

    requested_profiles = sort(unique(Int.(profile_indices)))
    all(i -> 1 <= i <= 7, requested_profiles) ||
        throw(ArgumentError("profile_indices must be selected from 1:7."))

    requested_N = sort(unique(Int.(N_values)))
    all(N -> N in HOMOGENEOUS_TIE_N_VALUES, requested_N) ||
        throw(ArgumentError(
            "N_values must be selected from $(HOMOGENEOUS_TIE_N_VALUES)."
        ))

    alpha_float = Float64.(alpha_values)
    requested_alpha_indices = Int[]

    for alpha in alpha_float
        index = findfirst(
            value -> isapprox(value, alpha; atol=1e-14, rtol=0.0),
            HOMOGENEOUS_TIE_ALPHA_VALUES
        )
        index === nothing &&
            throw(ArgumentError(
                "alpha_values must be selected from " *
                "$(HOMOGENEOUS_TIE_ALPHA_VALUES)."
            ))
        push!(requested_alpha_indices, index)
    end

    sort!(unique!(requested_alpha_indices))
    requested_N_indices = [
        findfirst(==(N), HOMOGENEOUS_TIE_N_VALUES)
        for N in requested_N
    ]

    requested_ids = _requested_case_ids(
        requested_profiles,
        requested_alpha_indices,
        requested_N_indices
    )

    output_path = String(output_file)
    grid = isfile(output_path) ?
        CSV.read(output_path, DataFrame) :
        DataFrame()

    completed_case_ids = _validate_checkpoint(
        grid;
        T=T,
        nruns=nruns,
        beta=beta,
        base_seed=base_seed
    )

    profiles = homogeneous_tie_profiles(; beta=beta)
    new_cases = 0
    stop_requested = false
    block_start = time()

    for profile_index in requested_profiles
        stop_requested && break

        profile = profiles[profile_index]
        mp_table = only(build_mp_tables(
            [profile.project_type],
            mp_index_fn;
            nx=table_nx,
            labels=[profile.name]
        ))

        for alpha_index in requested_alpha_indices
            stop_requested && break
            alphaM = HOMOGENEOUS_TIE_ALPHA_VALUES[alpha_index]

            for N_index in requested_N_indices
                N = HOMOGENEOUS_TIE_N_VALUES[N_index]
                case_id = homogeneous_tie_case_id(
                    profile_index,
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
                instance_seed = Int(base_seed) + case_id

                result = simulate_homogeneous_tie_case(
                    profile.project_type,
                    mp_table,
                    N,
                    M;
                    x_initial=x_initial,
                    T=T,
                    nruns=nruns,
                    seed=instance_seed,
                    threaded=threaded
                )

                result.all_rewards_finite ||
                    error("Nonfinite reward in case $case_id.")
                result.all_priorities_finite ||
                    error("Nonfinite priority in case $case_id.")

                case_df = result.rows
                case_df[!, :case_id] = fill(case_id, nrow(case_df))
                case_df[!, :profile_index] =
                    fill(profile_index, nrow(case_df))
                case_df[!, :profile] = fill(profile.name, nrow(case_df))
                case_df[!, :family] = fill(profile.family, nrow(case_df))
                case_df[!, :p01] = fill(profile.p01, nrow(case_df))
                case_df[!, :rho] = fill(profile.rho, nrow(case_df))
                case_df[!, :kappa] = fill(profile.kappa, nrow(case_df))
                case_df[!, :reward] = fill(profile.r, nrow(case_df))
                case_df[!, :alpha_index] =
                    fill(alpha_index, nrow(case_df))
                case_df[!, :alphaM_target] =
                    fill(alphaM, nrow(case_df))
                case_df[!, :N] = fill(N, nrow(case_df))
                case_df[!, :N_index] = fill(N_index, nrow(case_df))
                case_df[!, :M] = fill(M, nrow(case_df))
                case_df[!, :capacity_ratio] = fill(M / N, nrow(case_df))
                case_df[!, :T] = fill(result.T, nrow(case_df))
                case_df[!, :nruns] = fill(result.nruns, nrow(case_df))
                case_df[!, :beta] = fill(result.beta, nrow(case_df))
                case_df[!, :beta_tail] =
                    fill(result.beta^result.T, nrow(case_df))
                case_df[!, :seed] = fill(instance_seed, nrow(case_df))
                case_df[!, :x_initial] =
                    fill(Float64(x_initial), nrow(case_df))
                case_df[!, :table_nx] = fill(Int(table_nx), nrow(case_df))
                case_df[!, :runner_revision] =
                    fill(_RUNNER_REVISION, nrow(case_df))
                case_df[!, :simulation_seconds] =
                    fill(result.elapsed_seconds, nrow(case_df))
                case_df[!, :all_rewards_finite] =
                    fill(result.all_rewards_finite, nrow(case_df))
                case_df[!, :all_priorities_finite] =
                    fill(result.all_priorities_finite, nrow(case_df))
                case_df[!, :exact_capacity_ok] =
                    fill(result.exact_capacity_ok, nrow(case_df))

                if nrow(grid) == 0
                    grid = case_df
                else
                    grid = vcat(grid, case_df; cols=:union)
                end

                sort!(grid, [:case_id, :policy])
                _atomic_csv_write(output_path, grid)

                push!(completed_case_ids, case_id)
                new_cases += 1

                completed_requested =
                    length(intersect(completed_case_ids, requested_ids))

                println(
                    "[$completed_requested/$(length(requested_ids))] " *
                    "profile=$(profile.name), alpha=$alphaM, N=$N, M=$M, " *
                    "simulation=$(round(result.elapsed_seconds; digits=2)) s, " *
                    "elapsed=$(round((time() - block_start) / 60; digits=1)) min, " *
                    "MP/random-belief mismatches=" *
                    "$(result.mp_random_action_mismatch_periods)"
                )
            end
        end
    end

    completed_requested =
        length(intersect(completed_case_ids, requested_ids))

    grid_check = DataFrame([(
        completed_instances_full_grid=length(completed_case_ids),
        expected_instances_full_grid=
            7 *
            length(HOMOGENEOUS_TIE_ALPHA_VALUES) *
            length(HOMOGENEOUS_TIE_N_VALUES),
        completed_instances_requested=completed_requested,
        expected_instances_requested=length(requested_ids),
        policy_rows=nrow(grid),
        new_instances_this_run=new_cases,
        all_rewards_finite=
            nrow(grid) == 0 ? true : all(grid.all_rewards_finite),
        all_priorities_finite=
            nrow(grid) == 0 ? true : all(grid.all_priorities_finite),
        exact_capacity_ok=
            nrow(grid) == 0 ? true : all(grid.exact_capacity_ok),
        all_mp_tables_nonnegative=
            nrow(grid) == 0 ? true : all(grid.mp_table_nonnegative),
        all_mp_tables_nondecreasing=
            nrow(grid) == 0 ? true : all(grid.mp_table_nondecreasing),
        total_mp_random_action_mismatch_periods=
            nrow(grid) == 0 ? 0 :
            sum(unique(select(
                grid,
                :case_id,
                :mp_random_action_mismatch_periods
            )).mp_random_action_mismatch_periods),
        all_mp_random_rewards_exact=
            nrow(grid) == 0 ? true : all(grid.mp_random_rewards_exact),
        wall_minutes_this_run=(time() - block_start) / 60
    )])

    @show abspath(output_path)
    display(grid_check)

    return (
        grid=grid,
        grid_check=grid_check,
        manifest=homogeneous_tie_manifest(; beta=beta),
        output_file=output_path
    )
end


"""
Strictly validate a completed homogeneous tie-grid CSV.  A successful return
contains the validated data and a one-row audit summary.
"""
function validate_homogeneous_tie_output(
    path::AbstractString;
    T::Integer=700,
    nruns::Integer=1_000,
    beta::Real=0.99,
    base_seed::Integer=20260820,
    require_complete::Bool=true
)
    isfile(path) || error("Missing homogeneous tie-grid CSV: $path")
    data = CSV.read(path, DataFrame)
    completed = _validate_checkpoint(
        data;
        T=T,
        nruns=nruns,
        beta=beta,
        base_seed=base_seed
    )

    expected_cases =
        7 *
        length(HOMOGENEOUS_TIE_ALPHA_VALUES) *
        length(HOMOGENEOUS_TIE_N_VALUES)

    if require_complete && length(completed) != expected_cases
        error(
            "The tie grid is incomplete: found $(length(completed)) of " *
            "$expected_cases cases."
        )
    end

    audit = DataFrame([(
        cases=length(completed),
        expected_cases=expected_cases,
        rows=nrow(data),
        expected_rows=_NPOLICIES * expected_cases,
        all_rewards_finite=all(data.all_rewards_finite),
        all_priorities_finite=all(data.all_priorities_finite),
        exact_capacity_ok=all(data.exact_capacity_ok),
        all_mp_tables_nonnegative=all(data.mp_table_nonnegative),
        all_mp_tables_nondecreasing=all(data.mp_table_nondecreasing),
        total_mp_random_action_mismatch_periods=
            sum(unique(select(
                data,
                :case_id,
                :mp_random_action_mismatch_periods
            )).mp_random_action_mismatch_periods),
        all_mp_random_rewards_exact=all(data.mp_random_rewards_exact)
    )])

    return (data=data, audit=audit)
end


end # module HomogeneousTieGridRkappaV2
