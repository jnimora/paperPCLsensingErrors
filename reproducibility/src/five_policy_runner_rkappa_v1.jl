module FivePolicyRunnerRkappa

using Random
using Statistics
using Distributions

import ..SevenPolicyPilotRkappa:
    _validate_instance,
    _fill_table_priorities!,
    _fill_myopic_priorities!,
    _select_actions!,
    _update_policy!,
    pilot_selfcheck

export FIVE_POLICY_ORDER,
       simulate_five_policies,
       run_five_policy_pilot,
       verify_against_seven_policy_result


const FIVE_POLICY_ORDER = (
    :mp_index,
    :myopic,
    :lwz4,
    :lagrangian,
    :lagrangian_forced
)

const _POLICY_LABELS = Dict(
    :mp_index => "MP index",
    :myopic => "Myopic",
    :lwz4 => "LWZ4 approximate index",
    :lagrangian => "Lagrangian-threshold policy",
    :lagrangian_forced => "Capacity-filled Lagrangian policy"
)

const _MP = 1
const _MYOPIC = 2
const _LWZ4 = 3
const _LAGRANGIAN = 4
const _LAGRANGIAN_FORCED = 5
const _NPOLICIES = length(FIVE_POLICY_ORDER)


function _summaries(
    normalized_rewards::Matrix{Float64},
    conf_level::Float64
)
    nruns, npolicies = size(normalized_rewards)
    critical_value = quantile(Normal(), 0.5 + conf_level / 2.0)
    rows = NamedTuple[]

    for policy_index in 1:npolicies
        samples = view(normalized_rewards, :, policy_index)
        sample_mean = mean(samples)
        sample_stderr = std(samples) / sqrt(nruns)

        push!(
            rows,
            (
                policy=String(FIVE_POLICY_ORDER[policy_index]),
                label=_POLICY_LABELS[FIVE_POLICY_ORDER[policy_index]],
                mean=sample_mean,
                stderr=sample_stderr,
                ci_low=sample_mean - critical_value * sample_stderr,
                ci_high=sample_mean + critical_value * sample_stderr,
                nruns=nruns
            )
        )
    end

    return rows
end


function _capacity_rows(
    active_minimum::Matrix{Int},
    active_maximum::Matrix{Int},
    active_total::Matrix{Int},
    idle_slots::Matrix{Int},
    T::Int,
    nruns::Int,
    M::Int
)
    rows = NamedTuple[]
    total_slots = T * nruns

    for policy_index in 1:_NPOLICIES
        push!(
            rows,
            (
                policy=String(FIVE_POLICY_ORDER[policy_index]),
                label=_POLICY_LABELS[FIVE_POLICY_ORDER[policy_index]],
                min_active=minimum(view(active_minimum, :, policy_index)),
                max_active=maximum(view(active_maximum, :, policy_index)),
                mean_active=
                    sum(view(active_total, :, policy_index)) / total_slots,
                idle_slots=sum(view(idle_slots, :, policy_index)),
                idle_slot_fraction=
                    sum(view(idle_slots, :, policy_index)) / total_slots,
                capacity=M
            )
        )
    end

    return rows
end


"""
    simulate_five_policies(initial_beliefs, type_of, types, M; ...)

Simulate only the five policies retained for the full grid: MP, myopic, LWZ4,
the Lagrangian-threshold policy, and the capacity-filled Lagrangian policy.
The policies use common ACK uniforms, deterministic project-label tie-breaking,
and run-specific seeds that are invariant to Julia thread scheduling.
"""
function simulate_five_policies(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector,
    M::Integer;
    mp_tables::AbstractVector,
    lwz_tables::AbstractVector,
    lagrangian_tables::AbstractVector,
    T::Integer=700,
    nruns::Integer=1_000,
    conf_level::Real=0.95,
    seed::Integer=20260810,
    lagrangian_positive_tol::Real=0.0,
    threaded::Bool=true
)
    N, beta = _validate_instance(
        initial_beliefs,
        type_of,
        types,
        M,
        mp_tables,
        lwz_tables,
        lagrangian_tables
    )

    T >= 1 || throw(ArgumentError("T must be positive."))
    nruns >= 2 || throw(ArgumentError("nruns must be at least 2."))
    0.0 < conf_level < 1.0 ||
        throw(ArgumentError("conf_level must lie in (0,1)."))
    lagrangian_positive_tol >= 0.0 ||
        throw(ArgumentError(
            "lagrangian_positive_tol must be nonnegative."
        ))

    Ti = Int(T)
    nrunsi = Int(nruns)
    Mi = Int(M)
    confidence = Float64(conf_level)
    positive_tol = Float64(lagrangian_positive_tol)

    x0 = Float64.(initial_beliefs)
    type_ids = Int.(type_of)
    type_vector = collect(types)
    discount_factors = [beta^t for t in 0:(Ti - 1)]

    # Drawing these first exactly matches the ACK streams of the original
    # seven-policy runner for the same seed.
    master_rng = MersenneTwister(seed)
    ack_seeds = rand(master_rng, UInt64, nrunsi)

    raw_discounted_rewards = zeros(Float64, nrunsi, _NPOLICIES)
    active_minimum = fill(typemax(Int), nrunsi, _NPOLICIES)
    active_maximum = fill(typemin(Int), nrunsi, _NPOLICIES)
    active_total = zeros(Int, nrunsi, _NPOLICIES)
    idle_slots = zeros(Int, nrunsi, _NPOLICIES)

    function simulate_one_run!(run_index::Int)
        ack_rng = MersenneTwister(ack_seeds[run_index])

        beliefs = [copy(x0) for _ in 1:_NPOLICIES]
        actions = [falses(N) for _ in 1:_NPOLICIES]
        priorities = [zeros(Float64, N) for _ in 1:_NPOLICIES]
        orders = [collect(1:N) for _ in 1:_NPOLICIES]
        ack_uniforms = zeros(Float64, N)
        rewards = zeros(Float64, _NPOLICIES)

        for period in 1:Ti
            rand!(ack_rng, ack_uniforms)

            _fill_table_priorities!(
                priorities[_MP],
                beliefs[_MP],
                type_ids,
                mp_tables
            )
            _select_actions!(
                actions[_MP],
                orders[_MP],
                priorities[_MP],
                Mi
            )

            _fill_myopic_priorities!(
                priorities[_MYOPIC],
                beliefs[_MYOPIC],
                type_ids,
                type_vector
            )
            _select_actions!(
                actions[_MYOPIC],
                orders[_MYOPIC],
                priorities[_MYOPIC],
                Mi
            )

            _fill_table_priorities!(
                priorities[_LWZ4],
                beliefs[_LWZ4],
                type_ids,
                lwz_tables
            )
            _select_actions!(
                actions[_LWZ4],
                orders[_LWZ4],
                priorities[_LWZ4],
                Mi
            )

            _fill_table_priorities!(
                priorities[_LAGRANGIAN],
                beliefs[_LAGRANGIAN],
                type_ids,
                lagrangian_tables
            )
            _select_actions!(
                actions[_LAGRANGIAN],
                orders[_LAGRANGIAN],
                priorities[_LAGRANGIAN],
                Mi;
                positive_only=true,
                positive_tol=positive_tol
            )

            _fill_table_priorities!(
                priorities[_LAGRANGIAN_FORCED],
                beliefs[_LAGRANGIAN_FORCED],
                type_ids,
                lagrangian_tables
            )
            _select_actions!(
                actions[_LAGRANGIAN_FORCED],
                orders[_LAGRANGIAN_FORCED],
                priorities[_LAGRANGIAN_FORCED],
                Mi
            )

            for policy_index in 1:_NPOLICIES
                number_active = count(actions[policy_index])
                active_minimum[run_index, policy_index] = min(
                    active_minimum[run_index, policy_index],
                    number_active
                )
                active_maximum[run_index, policy_index] = max(
                    active_maximum[run_index, policy_index],
                    number_active
                )
                active_total[run_index, policy_index] += number_active
                idle_slots[run_index, policy_index] += number_active < Mi

                period_reward = _update_policy!(
                    beliefs[policy_index],
                    actions[policy_index],
                    ack_uniforms,
                    type_ids,
                    type_vector
                )

                rewards[policy_index] +=
                    discount_factors[period] * period_reward
            end
        end

        raw_discounted_rewards[run_index, :] .= rewards
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
    normalization = (1.0 - beta) / N
    normalized_rewards = normalization .* raw_discounted_rewards

    all(isfinite, normalized_rewards) ||
        error("The simulation produced a nonfinite normalized reward.")

    for policy_index in (
        _MP,
        _MYOPIC,
        _LWZ4,
        _LAGRANGIAN_FORCED
    )
        minimum(view(active_minimum, :, policy_index)) == Mi &&
        maximum(view(active_maximum, :, policy_index)) == Mi ||
            error(
                "Policy $(FIVE_POLICY_ORDER[policy_index]) failed to use " *
                "exactly M=$Mi activations."
            )
    end

    minimum(view(active_minimum, :, _LAGRANGIAN)) >= 0 &&
    maximum(view(active_maximum, :, _LAGRANGIAN)) <= Mi ||
        error("The Lagrangian-threshold policy violated capacity.")

    return (
        policies=collect(FIVE_POLICY_ORDER),
        summary=_summaries(normalized_rewards, confidence),
        capacity=_capacity_rows(
            active_minimum,
            active_maximum,
            active_total,
            idle_slots,
            Ti,
            nrunsi,
            Mi
        ),
        normalized_rewards=normalized_rewards,
        active_minimum=active_minimum,
        active_maximum=active_maximum,
        active_total=active_total,
        idle_slots=idle_slots,
        N=N,
        M=Mi,
        T=Ti,
        nruns=nrunsi,
        beta=beta,
        beta_tail=beta^Ti,
        seed=Int(seed),
        threaded=threaded,
        threads=Threads.nthreads(),
        elapsed_seconds=elapsed_seconds,
        seconds_per_replication=elapsed_seconds / nrunsi,
        lwz_fallback_count=sum(table.fallback_count for table in lwz_tables),
        lwz_fallback_by_type=[table.fallback_count for table in lwz_tables],
        all_rewards_finite=all(isfinite, normalized_rewards),
        all_priorities_finite=
            all(table -> all(isfinite, table.values), mp_tables) &&
            all(table -> all(isfinite, table.values), lwz_tables) &&
            all(table -> all(isfinite, table.values), lagrangian_tables)
    )
end


"""
Run the five-policy simulation and optionally perform a short fixed-seed
reproducibility check.
"""
function run_five_policy_pilot(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector,
    M::Integer;
    mp_tables::AbstractVector,
    lwz_tables::AbstractVector,
    lagrangian_tables::AbstractVector,
    T::Integer=700,
    nruns::Integer=1_000,
    conf_level::Real=0.95,
    seed::Integer=20260810,
    lagrangian_positive_tol::Real=0.0,
    threaded::Bool=true,
    verify_reproducibility::Bool=false
)
    tie_breaking_ok = pilot_selfcheck()

    primary = simulate_five_policies(
        initial_beliefs,
        type_of,
        types,
        M;
        mp_tables=mp_tables,
        lwz_tables=lwz_tables,
        lagrangian_tables=lagrangian_tables,
        T=T,
        nruns=nruns,
        conf_level=conf_level,
        seed=seed,
        lagrangian_positive_tol=lagrangian_positive_tol,
        threaded=threaded
    )

    reproducibility_ok = true
    reproducibility_T = min(Int(T), 20)
    reproducibility_nruns = min(Int(nruns), 5)

    if verify_reproducibility
        check_seed = Int(seed) + 1_000_003

        check_one = simulate_five_policies(
            initial_beliefs,
            type_of,
            types,
            M;
            mp_tables=mp_tables,
            lwz_tables=lwz_tables,
            lagrangian_tables=lagrangian_tables,
            T=reproducibility_T,
            nruns=reproducibility_nruns,
            conf_level=conf_level,
            seed=check_seed,
            lagrangian_positive_tol=lagrangian_positive_tol,
            threaded=threaded
        )

        check_two = simulate_five_policies(
            initial_beliefs,
            type_of,
            types,
            M;
            mp_tables=mp_tables,
            lwz_tables=lwz_tables,
            lagrangian_tables=lagrangian_tables,
            T=reproducibility_T,
            nruns=reproducibility_nruns,
            conf_level=conf_level,
            seed=check_seed,
            lagrangian_positive_tol=lagrangian_positive_tol,
            threaded=threaded
        )

        reproducibility_ok =
            isequal(
                check_one.normalized_rewards,
                check_two.normalized_rewards
            ) &&
            isequal(check_one.active_total, check_two.active_total) &&
            isequal(check_one.idle_slots, check_two.idle_slots)

        reproducibility_ok ||
            error("The fixed-seed reproducibility check failed.")
    end

    return merge(
        primary,
        (
            tie_breaking_ok=tie_breaking_ok,
            reproducibility_checked=verify_reproducibility,
            reproducibility_ok=reproducibility_ok,
            reproducibility_T=reproducibility_T,
            reproducibility_nruns=reproducibility_nruns
        )
    )
end


"""
Verify that the new runner reproduces the first five columns of a previously
computed seven-policy result exactly when called with identical inputs and seed.
"""
function verify_against_seven_policy_result(five, seven)
    size(seven.normalized_rewards, 2) >= _NPOLICIES ||
        throw(DimensionMismatch("The comparison result has fewer than five policies."))

    policy_order_ok =
        collect(FIVE_POLICY_ORDER) == seven.policies[1:_NPOLICIES] &&
        five.policies == seven.policies[1:_NPOLICIES]

    rewards_exact = isequal(
        five.normalized_rewards,
        seven.normalized_rewards[:, 1:_NPOLICIES]
    )

    active_totals_exact = isequal(
        five.active_total,
        seven.active_total[:, 1:_NPOLICIES]
    )

    idle_slots_exact = isequal(
        five.idle_slots,
        seven.idle_slots[:, 1:_NPOLICIES]
    )

    maximum_absolute_reward_difference = maximum(
        abs.(
            five.normalized_rewards .-
            seven.normalized_rewards[:, 1:_NPOLICIES]
        )
    )

    all_exact =
        policy_order_ok &&
        rewards_exact &&
        active_totals_exact &&
        idle_slots_exact

    all_exact ||
        error("The five-policy runner does not exactly match the seven-policy runner.")

    return (
        policy_order_ok=policy_order_ok,
        rewards_exact=rewards_exact,
        active_totals_exact=active_totals_exact,
        idle_slots_exact=idle_slots_exact,
        maximum_absolute_reward_difference=
            maximum_absolute_reward_difference,
        all_exact=all_exact
    )
end


end # module FivePolicyRunnerRkappa
