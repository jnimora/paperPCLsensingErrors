module SevenPolicyPilotRkappa

using Random
using Statistics
using Distributions

using ..SensingErrorBenchmarkIndices:
    BSFProjectType,
    PriorityTable,
    lookup_priority

export SEVEN_POLICY_ORDER,
       build_mp_tables,
       simulate_seven_policies,
       run_seven_policy_pilot,
       run_representative_seven_policy_pilot,
       pilot_summary_rows,
       pilot_capacity_rows,
       pilot_selfcheck


const SEVEN_POLICY_ORDER = (
    :mp_index,
    :myopic,
    :lwz4,
    :lagrangian,
    :lagrangian_forced,
    :round_robin,
    :random
)

const _POLICY_LABELS = Dict(
    :mp_index => "MP index",
    :myopic => "Myopic",
    :lwz4 => "LWZ4 approximate index",
    :lagrangian => "Standard Lagrangian",
    :lagrangian_forced => "Forced-capacity Lagrangian",
    :round_robin => "Round-robin",
    :random => "Random"
)

const _MP = 1
const _MYOPIC = 2
const _LWZ4 = 3
const _LAGRANGIAN = 4
const _LAGRANGIAN_FORCED = 5
const _ROUND_ROBIN = 6
const _RANDOM = 7
const _NPOLICIES = length(SEVEN_POLICY_ORDER)


"""
    build_mp_tables(types, mp_index_fn; nx=4001, labels=nothing)

Build type-specific lookup tables for the notebook MP index. The callback must
accept `(x, project_type)` and return a finite scalar.
"""
function build_mp_tables(
    types::AbstractVector{BSFProjectType},
    mp_index_fn;
    nx::Integer=4001,
    labels::Union{Nothing,AbstractVector}=nothing
)
    !isempty(types) || throw(ArgumentError("types must be nonempty."))
    nx >= 2 || throw(ArgumentError("nx must be at least 2."))

    if labels !== nothing
        length(labels) == length(types) ||
            throw(DimensionMismatch("labels must have one entry per type."))
    end

    xgrid = collect(range(0.0, 1.0; length=Int(nx)))
    tables = PriorityTable[]

    for type_id in eachindex(types)
        project_type = types[type_id]
        values = Vector{Float64}(undef, length(xgrid))

        for grid_index in eachindex(xgrid)
            value = Float64(mp_index_fn(xgrid[grid_index], project_type))
            isfinite(value) ||
                error(
                    "The MP-index callback returned $value for type " *
                    "$type_id at x=$(xgrid[grid_index])."
                )
            values[grid_index] = value
        end

        label = labels === nothing ?
                "type $type_id" :
                String(labels[type_id])

        push!(
            tables,
            PriorityTable(
                :mp_index,
                type_id,
                label,
                xgrid,
                values,
                0
            )
        )
    end

    return tables
end


@inline _phi0(x::Float64, p::BSFProjectType) = p.p01 + p.rho * x

@inline function _phi1(x::Float64, p::BSFProjectType)
    denominator = 1.0 - p.kappa * x

    if denominator <= 0.0
        return p.p01 + p.rho
    end

    return p.p01 +
           p.rho * (1.0 - p.kappa) * x / denominator
end


function _validate_tables(
    tables::AbstractVector{PriorityTable},
    ntypes::Integer,
    name::AbstractString
)
    length(tables) == ntypes ||
        throw(DimensionMismatch(
            "$name must contain exactly one table per project type."
        ))

    for type_id in 1:ntypes
        tables[type_id].type_id == type_id ||
            throw(ArgumentError(
                "$name must be stored in increasing type-id order."
            ))

        all(isfinite, tables[type_id].values) ||
            throw(ArgumentError("$name contains a nonfinite priority."))
    end

    return nothing
end


function _validate_instance(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector{BSFProjectType},
    M::Integer,
    mp_tables::AbstractVector{PriorityTable},
    lwz_tables::AbstractVector{PriorityTable},
    lagrangian_tables::AbstractVector{PriorityTable}
)
    N = length(initial_beliefs)

    N >= 2 || throw(ArgumentError("At least two projects are required."))
    length(type_of) == N ||
        throw(DimensionMismatch(
            "initial_beliefs and type_of must have equal lengths."
        ))
    !isempty(types) || throw(ArgumentError("types must be nonempty."))
    1 <= M < N || throw(ArgumentError("Require 1 <= M < N."))

    all(x -> isfinite(x) && 0.0 <= x <= 1.0, initial_beliefs) ||
        throw(ArgumentError(
            "Every initial belief must be finite and lie in [0,1]."
        ))

    all(k -> 1 <= k <= length(types), type_of) ||
        throw(ArgumentError("Every type id must index types."))

    beta = types[1].beta
    all(p -> isapprox(p.beta, beta; atol=0.0, rtol=1e-14), types) ||
        throw(ArgumentError("All project types must share beta."))

    _validate_tables(mp_tables, length(types), "mp_tables")
    _validate_tables(lwz_tables, length(types), "lwz_tables")
    _validate_tables(
        lagrangian_tables,
        length(types),
        "lagrangian_tables"
    )

    return N, beta
end


function _fill_table_priorities!(
    priorities::Vector{Float64},
    beliefs::Vector{Float64},
    type_of::Vector{Int},
    tables::AbstractVector{PriorityTable}
)
    @inbounds for project in eachindex(beliefs)
        priorities[project] = lookup_priority(
            tables[type_of[project]],
            beliefs[project]
        )
    end

    all(isfinite, priorities) ||
        error("A table-based policy produced a nonfinite priority.")

    return priorities
end


function _fill_myopic_priorities!(
    priorities::Vector{Float64},
    beliefs::Vector{Float64},
    type_of::Vector{Int},
    types::Vector{BSFProjectType}
)
    @inbounds for project in eachindex(beliefs)
        p = types[type_of[project]]
        priorities[project] = p.r * p.kappa * beliefs[project]
    end

    all(isfinite, priorities) ||
        error("The myopic policy produced a nonfinite priority.")

    return priorities
end


"""
Fill `actions` using descending priority and increasing project label for exact
ties. With `positive_only=true`, select at most `M` projects whose priority is
strictly greater than `positive_tol`; otherwise select exactly `M` projects.
"""
function _select_actions!(
    actions::BitVector,
    order::Vector{Int},
    priorities::Vector{Float64},
    M::Int;
    positive_only::Bool=false,
    positive_tol::Float64=0.0
)
    N = length(priorities)
    length(actions) == N || throw(DimensionMismatch("actions has wrong size."))
    length(order) == N || throw(DimensionMismatch("order has wrong size."))

    @inbounds for i in 1:N
        order[i] = i
    end

    sort!(order; by=i -> (-priorities[i], i))
    fill!(actions, false)

    selected = 0
    @inbounds for project in order
        selected == M && break

        if positive_only && priorities[project] <= positive_tol
            break
        end

        actions[project] = true
        selected += 1
    end

    return selected
end


function _round_robin_actions!(
    actions::BitVector,
    start::Int,
    M::Int
)
    N = length(actions)
    fill!(actions, false)

    @inbounds for offset in 0:(M - 1)
        project = mod1(start + offset, N)
        actions[project] = true
    end

    return mod1(start + M, N)
end


function _random_actions!(
    actions::BitVector,
    permutation::Vector{Int},
    rng::AbstractRNG,
    M::Int
)
    randperm!(rng, permutation)
    fill!(actions, false)

    @inbounds for position in 1:M
        actions[permutation[position]] = true
    end

    return nothing
end


function _update_policy!(
    beliefs::Vector{Float64},
    actions::BitVector,
    ack_uniforms::Vector{Float64},
    type_of::Vector{Int},
    types::Vector{BSFProjectType}
)
    reward = 0.0

    @inbounds for project in eachindex(beliefs)
        p = types[type_of[project]]
        x = beliefs[project]

        if actions[project]
            if ack_uniforms[project] < p.kappa * x
                reward += p.r
                beliefs[project] = p.p01 + p.rho
            else
                beliefs[project] = _phi1(x, p)
            end
        else
            beliefs[project] = _phi0(x, p)
        end

        y = beliefs[project]
        if !(isfinite(y) && -1e-12 <= y <= 1.0 + 1e-12)
            error(
                "Belief update left [0,1]: project=$project, " *
                "old=$x, new=$y."
            )
        end
        beliefs[project] = clamp(y, 0.0, 1.0)
    end

    return reward
end


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
                policy=String(SEVEN_POLICY_ORDER[policy_index]),
                label=_POLICY_LABELS[SEVEN_POLICY_ORDER[policy_index]],
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
                policy=String(SEVEN_POLICY_ORDER[policy_index]),
                label=_POLICY_LABELS[SEVEN_POLICY_ORDER[policy_index]],
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
    simulate_seven_policies(initial_beliefs, type_of, types, M; ...)

Simulate MP, myopic, LWZ4, standard Lagrangian, forced-capacity Lagrangian,
round-robin, and random policies. Each run uses common ACK uniforms across all
seven policies. The random policy's action sampling uses a separate stream.
Run-specific seeds make results invariant to Julia thread scheduling.
"""
function simulate_seven_policies(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector{BSFProjectType},
    M::Integer;
    mp_tables::AbstractVector{PriorityTable},
    lwz_tables::AbstractVector{PriorityTable},
    lagrangian_tables::AbstractVector{PriorityTable},
    T::Integer=100,
    nruns::Integer=100,
    conf_level::Real=0.95,
    seed::Integer=20260802,
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

    master_rng = MersenneTwister(seed)
    ack_seeds = rand(master_rng, UInt64, nrunsi)
    random_action_seeds = rand(master_rng, UInt64, nrunsi)

    raw_discounted_rewards = zeros(Float64, nrunsi, _NPOLICIES)
    active_minimum = fill(typemax(Int), nrunsi, _NPOLICIES)
    active_maximum = fill(typemin(Int), nrunsi, _NPOLICIES)
    active_total = zeros(Int, nrunsi, _NPOLICIES)
    idle_slots = zeros(Int, nrunsi, _NPOLICIES)

    function simulate_one_run!(run_index::Int)
        ack_rng = MersenneTwister(ack_seeds[run_index])
        random_action_rng = MersenneTwister(
            random_action_seeds[run_index]
        )

        beliefs = [copy(x0) for _ in 1:_NPOLICIES]
        actions = [falses(N) for _ in 1:_NPOLICIES]
        priorities = [zeros(Float64, N) for _ in 1:5]
        orders = [collect(1:N) for _ in 1:5]
        permutation = collect(1:N)
        ack_uniforms = zeros(Float64, N)
        rewards = zeros(Float64, _NPOLICIES)
        round_robin_start = 1

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

            round_robin_start = _round_robin_actions!(
                actions[_ROUND_ROBIN],
                round_robin_start,
                Mi
            )

            _random_actions!(
                actions[_RANDOM],
                permutation,
                random_action_rng,
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

    exact_capacity_indices = (
        _MP,
        _MYOPIC,
        _LWZ4,
        _LAGRANGIAN_FORCED,
        _ROUND_ROBIN,
        _RANDOM
    )

    for policy_index in exact_capacity_indices
        minimum(view(active_minimum, :, policy_index)) == Mi &&
        maximum(view(active_maximum, :, policy_index)) == Mi ||
            error(
                "Policy $(SEVEN_POLICY_ORDER[policy_index]) failed to use " *
                "exactly M=$Mi activations."
            )
    end

    minimum(view(active_minimum, :, _LAGRANGIAN)) >= 0 &&
    maximum(view(active_maximum, :, _LAGRANGIAN)) <= Mi ||
        error("The standard Lagrangian policy violated capacity.")

    return (
        policies=collect(SEVEN_POLICY_ORDER),
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


function pilot_selfcheck()
    priorities = [3.0, 3.0, 2.0, 1.0]
    actions = falses(4)
    order = collect(1:4)
    selected = _select_actions!(actions, order, priorities, 2)

    selected == 2 || error("Tie-breaking self-check selected wrong count.")
    findall(actions) == [1, 2] ||
        error("Tie-breaking self-check did not prefer smaller labels.")

    positive_actions = falses(4)
    positive_order = collect(1:4)
    positive_selected = _select_actions!(
        positive_actions,
        positive_order,
        [-1.0, 0.0, 0.0, 0.0],
        3;
        positive_only=true
    )

    positive_selected == 0 ||
        error("Positive-only self-check should leave capacity idle.")

    return true
end


"""
Run the requested pilot and a small repeated reproducibility check. The two
reproducibility runs use identical run-specific seeds and must agree exactly.
"""
function run_seven_policy_pilot(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector{BSFProjectType},
    M::Integer;
    mp_tables::AbstractVector{PriorityTable},
    lwz_tables::AbstractVector{PriorityTable},
    lagrangian_tables::AbstractVector{PriorityTable},
    T::Integer=100,
    nruns::Integer=100,
    conf_level::Real=0.95,
    seed::Integer=20260802,
    lagrangian_positive_tol::Real=0.0,
    threaded::Bool=true,
    verify_reproducibility::Bool=true
)
    tie_breaking_ok = pilot_selfcheck()

    primary = simulate_seven_policies(
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

        check_one = simulate_seven_policies(
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

        check_two = simulate_seven_policies(
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
Construct and run the representative 50--50 two-type pilot used in the
notebook. The supplied LWZ4 and Lagrangian tables are reused, while a fresh MP
lookup table is built from `mp_index_fn` and timed separately.
"""
function run_representative_seven_policy_pilot(
    types::AbstractVector{BSFProjectType},
    labels::AbstractVector,
    lwz_tables::AbstractVector{PriorityTable},
    lagrangian_tables::AbstractVector{PriorityTable},
    mp_index_fn;
    N::Integer=100,
    M::Integer=10,
    prop_A::Real=0.50,
    x_initial::Real=0.50,
    nx::Integer=4001,
    T::Integer=100,
    nruns::Integer=100,
    conf_level::Real=0.95,
    seed::Integer=20260802,
    lagrangian_positive_tol::Real=0.0,
    threaded::Bool=true,
    verify_reproducibility::Bool=true
)
    length(types) == 2 ||
        throw(ArgumentError("The representative pilot requires two types."))
    length(labels) == 2 ||
        throw(DimensionMismatch("labels must contain two entries."))
    N >= 2 || throw(ArgumentError("N must be at least 2."))
    1 <= M < N || throw(ArgumentError("Require 1 <= M < N."))
    0.0 <= prop_A <= 1.0 ||
        throw(ArgumentError("prop_A must lie in [0,1]."))
    isfinite(x_initial) && 0.0 <= x_initial <= 1.0 ||
        throw(ArgumentError("x_initial must be finite and lie in [0,1]."))

    Ni = Int(N)
    n_A = round(Int, Float64(prop_A) * Ni)
    n_B = Ni - n_A
    type_of = vcat(fill(1, n_A), fill(2, n_B))
    initial_beliefs = fill(Float64(x_initial), Ni)

    table_start = time_ns()
    mp_tables = build_mp_tables(
        types,
        mp_index_fn;
        nx=nx,
        labels=labels
    )
    mp_table_seconds = (time_ns() - table_start) / 1e9

    result = run_seven_policy_pilot(
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
        threaded=threaded,
        verify_reproducibility=verify_reproducibility
    )

    return merge(
        result,
        (
            mp_tables=mp_tables,
            mp_table_seconds=mp_table_seconds,
            type_A_count=n_A,
            type_B_count=n_B,
            prop_A=Float64(prop_A),
            x_initial=Float64(x_initial),
            nx=Int(nx)
        )
    )
end


pilot_summary_rows(result) = result.summary
pilot_capacity_rows(result) = result.capacity


end # module SevenPolicyPilotRkappa
