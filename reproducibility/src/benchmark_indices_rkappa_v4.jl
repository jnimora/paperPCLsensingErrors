module SensingErrorBenchmarkIndices

using LinearAlgebra
using PGFPlotsX

export BSFProjectType,
       PCLCallbacks,
       notebook_callbacks,
       LagrangianPlan,
       PriorityTable,
       solve_lagrangian_plan,
       lagrangian_priority,
       build_lagrangian_tables,
       lwz_approx_index,
       lwz_orbit_diagnostic,
       build_lwz_tables,
       lookup_priority,
       priority_vector,
       select_priority_actions,
       select_lagrangian_actions,
       select_lwz_actions,
       monotonicity_report,
       monotonicity_reports,
       plot_priority_tables,
       plot_lwz_lagrangian_indices,
       benchmark_index_selfcheck


# ============================================================================
# Model and callback interfaces
# ============================================================================

"""
    BSFProjectType(; p01, rho, kappa, r, beta)

Parameters of one binary-success-feedback project type:

    phi0(x) = p01 + rho*x,
    phi1(x) = p01 + rho*((1-kappa)*x)/(1-kappa*x),
    p11     = p01 + rho,
    R(x,1)  = r*kappa*x.
"""
struct BSFProjectType
    p01::Float64
    rho::Float64
    kappa::Float64
    r::Float64
    beta::Float64

    function BSFProjectType(
        p01::Real,
        rho::Real,
        kappa::Real,
        r::Real,
        beta::Real
    )
        p01f   = Float64(p01)
        rhof   = Float64(rho)
        kappaf = Float64(kappa)
        rf     = Float64(r)
        betaf  = Float64(beta)

        all(isfinite, (p01f, rhof, kappaf, rf, betaf)) ||
            throw(ArgumentError("All project parameters must be finite."))

        0.0 < p01f < 1.0 ||
            throw(ArgumentError("Require 0 < p01 < 1."))

        0.0 < rhof < 1.0 - p01f ||
            throw(ArgumentError("Require 0 < rho < 1-p01."))

        0.0 < kappaf < 1.0 ||
            throw(ArgumentError("Require 0 < kappa < 1."))

        rf > 0.0 ||
            throw(ArgumentError("Require r > 0."))

        0.0 < betaf < 1.0 ||
            throw(ArgumentError("Require 0 < beta < 1."))

        return new(p01f, rhof, kappaf, rf, betaf)
    end
end

BSFProjectType(; p01, rho, kappa, r, beta) =
    BSFProjectType(p01, rho, kappa, r, beta)


@inline _p11(p::BSFProjectType) = p.p01 + p.rho

@inline _phi0(x::Real, p::BSFProjectType) =
    p.p01 + p.rho * Float64(x)

@inline function _phi1(x::Real, p::BSFProjectType)
    xf = Float64(x)
    denominator = 1.0 - p.kappa * xf

    denominator > 0.0 ||
        throw(DomainError(
            (xf, p.kappa),
            "The no-ACK posterior denominator must be positive."
        ))

    return p.p01 +
           p.rho * (1.0 - p.kappa) * xf / denominator
end


"""
Callbacks connecting this file to the notebook's existing PCL routines.

Every callback uses a compact positional interface:

    zstar(lambda, project_type)
    F(x, z, project_type)
    G(x, z, project_type)
    f(x, z, project_type)
    g(x, z, project_type)
"""
struct PCLCallbacks{TZ,TF,TG,Tf,Tg}
    zstar::TZ
    F::TF
    G::TG
    f::Tf
    g::Tg
end


@inline function _scalar_metric(value)
    scalar = value isa Tuple ? first(value) : value
    result = Float64(scalar)

    isfinite(result) ||
        error("A PCL callback returned a nonfinite scalar: $result")

    return result
end


"""
    notebook_callbacks(; zstar_fn, F_metric_fn, G_metric_fn,
                         f_metric_fn, g_metric_fn, ...)

Adapt the functions already defined in the notebook (`zstar`, `F_metric`,
`G_metric`, `f_metric2`, and `g_metric2`) to `PCLCallbacks`.
"""
function notebook_callbacks(
    ;
    zstar_fn,
    F_metric_fn,
    G_metric_fn,
    f_metric_fn,
    g_metric_fn,
    epsilon::Real=1e-10,
    xatol::Real=1e-10,
    lambda_atol::Real=1e-10,
    maxiter::Integer=200
)
    epsilonf = Float64(epsilon)
    xatolf = Float64(xatol)
    lambda_atolf = Float64(lambda_atol)
    maxiteri = Int(maxiter)

    epsilonf > 0.0 ||
        throw(ArgumentError("epsilon must be positive."))

    xatolf > 0.0 ||
        throw(ArgumentError("xatol must be positive."))

    lambda_atolf > 0.0 ||
        throw(ArgumentError("lambda_atol must be positive."))

    maxiteri >= 1 ||
        throw(ArgumentError("maxiter must be positive."))

    zstar_callback = function (lambda::Real, p::BSFProjectType)
        return Float64(
            zstar_fn(
                Float64(lambda);
                p01=p.p01,
                ρ=p.rho,
                κ=p.kappa,
                r=p.r,
                β=p.beta,
                ε=epsilonf,
                xatol=xatolf,
                λatol=lambda_atolf,
                maxiter=maxiteri
            )
        )
    end

    F_callback = function (x::Real, z::Real, p::BSFProjectType)
        return _scalar_metric(
            F_metric_fn(
                Float64(x),
                Float64(z);
                p01=p.p01,
                ρ=p.rho,
                κ=p.kappa,
                r=p.r,
                β=p.beta,
                ε=epsilonf
            )
        )
    end

    G_callback = function (x::Real, z::Real, p::BSFProjectType)
        return _scalar_metric(
            G_metric_fn(
                Float64(x),
                Float64(z);
                p01=p.p01,
                ρ=p.rho,
                κ=p.kappa,
                β=p.beta,
                ε=epsilonf
            )
        )
    end

    f_callback = function (x::Real, z::Real, p::BSFProjectType)
        return _scalar_metric(
            f_metric_fn(
                Float64(x),
                Float64(z);
                p01=p.p01,
                ρ=p.rho,
                κ=p.kappa,
                r=p.r,
                β=p.beta,
                ε=epsilonf
            )
        )
    end

    g_callback = function (x::Real, z::Real, p::BSFProjectType)
        return _scalar_metric(
            g_metric_fn(
                Float64(x),
                Float64(z);
                p01=p.p01,
                ρ=p.rho,
                κ=p.kappa,
                β=p.beta,
                ε=epsilonf
            )
        )
    end

    return PCLCallbacks(
        zstar_callback,
        F_callback,
        G_callback,
        f_callback,
        g_callback
    )
end


# ============================================================================
# Grouped Lagrangian dual and Lagrangian-index priorities
# ============================================================================

struct _InitialGroup
    type_id::Int
    x::Float64
    multiplicity::Int
end


function _validate_instance(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector{BSFProjectType},
    M::Integer
)
    N = length(initial_beliefs)

    N >= 2 ||
        throw(ArgumentError("At least two projects are required."))

    length(type_of) == N ||
        throw(DimensionMismatch(
            "initial_beliefs and type_of must have equal lengths."
        ))

    !isempty(types) ||
        throw(ArgumentError("types must be nonempty."))

    all(x -> isfinite(x) && 0.0 <= x <= 1.0, initial_beliefs) ||
        throw(ArgumentError(
            "Every initial belief must be finite and lie in [0,1]."
        ))

    all(k -> 1 <= k <= length(types), type_of) ||
        throw(ArgumentError("Every type id must index types."))

    1 <= M < N ||
        throw(ArgumentError("Require 1 <= M < N."))

    beta = types[1].beta

    all(p -> isapprox(p.beta, beta; atol=0.0, rtol=1e-14), types) ||
        throw(ArgumentError(
            "All project types in one instance must share beta."
        ))

    return N, beta
end


function _compress_initial_state(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer}
)
    counts = Dict{Tuple{Int,Float64},Int}()

    for i in eachindex(initial_beliefs, type_of)
        key = (Int(type_of[i]), Float64(initial_beliefs[i]))
        counts[key] = get(counts, key, 0) + 1
    end

    groups = _InitialGroup[
        _InitialGroup(key[1], key[2], multiplicity)
        for (key, multiplicity) in counts
    ]

    sort!(groups; by=group -> (group.type_id, group.x))

    return groups
end


function _dual_evaluation(
    lambda::Real,
    groups::AbstractVector{_InitialGroup},
    types::AbstractVector{BSFProjectType},
    M::Integer,
    N::Integer,
    callbacks::PCLCallbacks
)
    lambdaf = Float64(lambda)
    beta = types[1].beta

    zstars = Vector{Float64}(undef, length(types))

    for type_id in eachindex(types)
        zstars[type_id] = callbacks.zstar(lambdaf, types[type_id])
    end

    sum_value = 0.0
    sum_work = 0.0

    for group in groups
        p = types[group.type_id]
        z = zstars[group.type_id]
        F = callbacks.F(group.x, z, p)
        G = callbacks.G(group.x, z, p)

        sum_value += group.multiplicity * (F - lambdaf * G)
        sum_work += group.multiplicity * G
    end

    value = M * lambdaf / (1.0 - beta) + sum_value
    subgradient = M / (1.0 - beta) - sum_work
    normalized_value = (1.0 - beta) * value / N

    return (
        value=value,
        normalized_value=normalized_value,
        subgradient=subgradient,
        total_work=sum_work,
        zstars=zstars
    )
end


"""
The grouped threshold-dual solution and the data shared by the standard and
forced-capacity Lagrangian-index policies.

`value_is_certified` must be set to `true` only when the single-project values
used by the callbacks have been independently certified as optimal. Otherwise
the result is a threshold-dual benchmark, not a rigorous upper bound.
"""
struct LagrangianPlan
    lambda_star::Float64
    value::Float64
    normalized_value::Float64
    subgradient::Float64
    zstars::Vector{Float64}
    types::Vector{BSFProjectType}
    M::Int
    N::Int
    lambda_lo::Float64
    lambda_hi::Float64
    iterations::Int
    value_is_certified::Bool
end


"""
    solve_lagrangian_plan(initial_beliefs, type_of, types, M, callbacks; ...)

Minimize the grouped threshold-dual objective over `lambda >= 0` by bisection
on its monotone subgradient. The same returned plan is used by both `Lag` and
`LagF`; only their final action-selection rules differ.
"""
function solve_lagrangian_plan(
    initial_beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    types::AbstractVector{BSFProjectType},
    M::Integer,
    callbacks::PCLCallbacks;
    lambda_tol::Real=1e-8,
    subgradient_tol::Real=1e-10,
    max_bisect_iter::Integer=100,
    max_expand::Integer=20,
    value_is_certified::Bool=false
)
    N, _ = _validate_instance(initial_beliefs, type_of, types, M)

    lambda_tolf = Float64(lambda_tol)
    subgradient_tolf = Float64(subgradient_tol)

    lambda_tolf > 0.0 ||
        throw(ArgumentError("lambda_tol must be positive."))

    subgradient_tolf >= 0.0 ||
        throw(ArgumentError("subgradient_tol must be nonnegative."))

    max_bisect_iter >= 1 ||
        throw(ArgumentError("max_bisect_iter must be positive."))

    max_expand >= 1 ||
        throw(ArgumentError("max_expand must be positive."))

    groups = _compress_initial_state(initial_beliefs, type_of)
    type_vector = collect(types)

    cache = Dict{Float64,NamedTuple}()

    evaluate = function (lambda::Real)
        lambdaf = Float64(lambda)
        return get!(cache, lambdaf) do
            _dual_evaluation(
                lambdaf,
                groups,
                type_vector,
                M,
                N,
                callbacks
            )
        end
    end

    at_zero = evaluate(0.0)

    if at_zero.subgradient >= -subgradient_tolf
        return LagrangianPlan(
            0.0,
            at_zero.value,
            at_zero.normalized_value,
            at_zero.subgradient,
            at_zero.zstars,
            type_vector,
            Int(M),
            N,
            0.0,
            0.0,
            0,
            value_is_certified
        )
    end

    # At a price no smaller than every possible expected one-period reward,
    # every activation has nonpositive expected net reward. This is a natural
    # initial right bracket; expansion below protects against numerical or
    # threshold-selection effects in the callback implementation.
    lambda_lo = 0.0
    lambda_hi = maximum(p.r * p.kappa for p in type_vector)
    at_hi = evaluate(lambda_hi)

    expansions = 0
    while at_hi.subgradient < -subgradient_tolf && expansions < max_expand
        lambda_lo = lambda_hi
        lambda_hi *= 2.0
        at_hi = evaluate(lambda_hi)
        expansions += 1
    end

    at_hi.subgradient >= -subgradient_tolf ||
        error(
            "Failed to bracket the grouped dual minimizer: " *
            "the subgradient remained negative."
        )

    iterations = 0

    while lambda_hi - lambda_lo > lambda_tolf &&
          iterations < max_bisect_iter

        lambda_mid = (lambda_lo + lambda_hi) / 2.0
        at_mid = evaluate(lambda_mid)

        if at_mid.subgradient <= 0.0
            lambda_lo = lambda_mid
        else
            lambda_hi = lambda_mid
        end

        iterations += 1
    end

    lambda_mid = (lambda_lo + lambda_hi) / 2.0
    candidates = unique(sort([lambda_lo, lambda_mid, lambda_hi]))
    candidate_values = [evaluate(lambda).value for lambda in candidates]
    best_index = argmin(candidate_values)
    lambda_star = candidates[best_index]
    best = evaluate(lambda_star)

    return LagrangianPlan(
        lambda_star,
        best.value,
        best.normalized_value,
        best.subgradient,
        best.zstars,
        type_vector,
        Int(M),
        N,
        lambda_lo,
        lambda_hi,
        iterations,
        value_is_certified
    )
end


"""
    lagrangian_priority(x, type_id, plan, callbacks)

Evaluate

    d_k^*(x) = f_k(x,z_k^*) - lambda^* g_k(x,z_k^*).

This is the exact one-step Lagrangian advantage whenever the threshold used in
the plan solves the single-project charge problem; otherwise it is the stated
PCL-based Lagrangian-index approximation.
"""
function lagrangian_priority(
    x::Real,
    type_id::Integer,
    plan::LagrangianPlan,
    callbacks::PCLCallbacks
)
    1 <= type_id <= length(plan.types) ||
        throw(ArgumentError("type_id does not index plan.types."))

    xf = Float64(x)

    isfinite(xf) && 0.0 <= xf <= 1.0 ||
        throw(ArgumentError("x must be finite and lie in [0,1]."))

    p = plan.types[type_id]
    z = plan.zstars[type_id]

    return callbacks.f(xf, z, p) -
           plan.lambda_star * callbacks.g(xf, z, p)
end


# ============================================================================
# Liu-Weber-Zhang four-iteration approximate Whittle index
# ============================================================================

struct _AffineSubsidyValue
    constant::Float64
    slope::Float64
end


@inline function _affine_at(value::_AffineSubsidyValue, subsidy::Real)
    return value.constant + value.slope * Float64(subsidy)
end


@inline function _phi0_iter(
    x::Float64,
    steps::Int,
    p::BSFProjectType
)
    fixed_point = p.p01 / (1.0 - p.rho)
    return fixed_point + (x - fixed_point) * p.rho^steps
end


"""
Return Liu et al.'s passive first-crossing time

    L(w,z) = min{k >= 0 : phi0^k(w) > z},

and the crossing state. `nothing` denotes an infinite crossing time.
The strict inequality agrees with their Eq. (52) and with the notebook's
passive-at-threshold convention.
"""
function _passive_first_crossing(
    w::Real,
    z::Real,
    p::BSFProjectType
)
    wf = Float64(w)
    zf = Float64(z)

    isfinite(wf) && 0.0 <= wf <= 1.0 ||
        throw(ArgumentError("w must be finite and lie in [0,1]."))

    isfinite(zf) && 0.0 <= zf <= 1.0 ||
        throw(ArgumentError("z must be finite and lie in [0,1]."))

    if wf > zf
        return (steps=0, crossing_state=wf)
    end

    fixed_point = p.p01 / (1.0 - p.rho)

    # If w <= z and z is at or above the passive fixed point, the passive
    # trajectory can never strictly upcross z. The same is true when w is
    # already at or above the fixed point, because phi0 then decreases.
    if zf >= fixed_point || wf >= fixed_point
        return (steps=nothing, crossing_state=fixed_point)
    end

    ratio = (fixed_point - zf) / (fixed_point - wf)
    raw_steps = log(ratio) / log(p.rho)
    steps = max(0, floor(Int, raw_steps) + 1)
    crossing_state = _phi0_iter(wf, steps, p)

    # Correct the rare floating-point off-by-one case at an exact breakpoint.
    while steps > 0
        previous_state = _phi0_iter(wf, steps - 1, p)

        if previous_state > zf
            steps -= 1
            crossing_state = previous_state
        else
            break
        end
    end

    correction_count = 0
    while !(crossing_state > zf)
        steps += 1
        crossing_state = _phi0_iter(wf, steps, p)
        correction_count += 1

        correction_count <= 8 ||
            error(
                "Could not resolve a strict passive crossing near a " *
                "floating-point threshold breakpoint."
            )
    end

    return (steps=steps, crossing_state=crossing_state)
end


struct _LWZExpansionRow
    passive_subsidy_coefficient::Float64
    reward_constant::Float64
    reset_coefficient::Float64
    failure_coefficient::Float64
    next_state::Union{Nothing,Float64}
    never_activates::Bool
end


function _lwz_expansion_row(
    state::Float64,
    threshold::Float64,
    p::BSFProjectType
)
    crossing = _passive_first_crossing(state, threshold, p)

    if isnothing(crossing.steps)
        return _LWZExpansionRow(
            1.0 / (1.0 - p.beta),
            0.0,
            0.0,
            0.0,
            nothing,
            true
        )
    end

    passive_steps = crossing.steps::Int
    y = crossing.crossing_state
    beta_to_L = p.beta^passive_steps
    success_probability = p.kappa * y

    subsidy_coefficient =
        (1.0 - beta_to_L) / (1.0 - p.beta)

    reward_constant = beta_to_L * p.r * success_probability
    reset_coefficient =
        beta_to_L * p.beta * success_probability
    failure_coefficient =
        beta_to_L * p.beta * (1.0 - success_probability)

    return _LWZExpansionRow(
        subsidy_coefficient,
        reward_constant,
        reset_coefficient,
        failure_coefficient,
        _phi1(y, p),
        false
    )
end


function _lwz_path(
    start::Float64,
    threshold::Float64,
    p::BSFProjectType,
    iterations::Int
)
    states = Float64[start]
    rows = _LWZExpansionRow[]

    for iteration in 0:iterations
        row = _lwz_expansion_row(states[end], threshold, p)
        push!(rows, row)

        if row.never_activates || iteration == iterations
            break
        end

        push!(states, row.next_state::Float64)
    end

    return states, rows
end


"""
Solve Liu et al.'s Eq. (59) expansion as an affine function of the passive
subsidy `m`. With `reset_value=nothing`, `start` must be `p11` and the reset
value is the first unknown in the system. Otherwise the already-computed
affine value at `p11` is inserted into the right-hand side.

For an `iterations=k` expansion, the terminal closure is

    V(k_{k+1}) = V(k_k),

as in the displayed finite system following their Eq. (60).
"""
function _solve_lwz_affine_value(
    start::Real,
    threshold::Real,
    p::BSFProjectType,
    iterations::Integer;
    reset_value::Union{Nothing,_AffineSubsidyValue}=nothing
)
    iterations >= 0 ||
        throw(ArgumentError("iterations must be nonnegative."))

    startf = Float64(start)
    thresholdf = Float64(threshold)

    states, rows = _lwz_path(
        startf,
        thresholdf,
        p,
        Int(iterations)
    )

    dimension = length(states)

    length(rows) == dimension ||
        error("Internal LWZ path construction produced inconsistent sizes.")

    A = Matrix{Float64}(I, dimension, dimension)
    rhs_constant = zeros(Float64, dimension)
    rhs_slope = zeros(Float64, dimension)

    for row_index in 1:dimension
        row = rows[row_index]

        if row.never_activates
            rhs_slope[row_index] =
                row.passive_subsidy_coefficient
            continue
        end

        rhs_constant[row_index] = row.reward_constant
        rhs_slope[row_index] = row.passive_subsidy_coefficient

        if isnothing(reset_value)
            # For the p11 system, V(p11) is unknown number 1.
            A[row_index, 1] -= row.reset_coefficient
        else
            reset = reset_value::_AffineSubsidyValue
            rhs_constant[row_index] +=
                row.reset_coefficient * reset.constant
            rhs_slope[row_index] +=
                row.reset_coefficient * reset.slope
        end

        if row_index < dimension
            A[row_index, row_index + 1] -=
                row.failure_coefficient
        else
            # Four-iteration implementation: V(k5)=V(k4).
            A[row_index, row_index] -=
                row.failure_coefficient
        end
    end

    constants = A \ rhs_constant
    slopes = A \ rhs_slope

    result = _AffineSubsidyValue(constants[1], slopes[1])

    all(isfinite, (result.constant, result.slope)) ||
        error("The LWZ affine system returned nonfinite coefficients.")

    return result
end


"""
Detailed result from one Liu-Weber-Zhang approximate-index evaluation.
"""
struct LWZIndexResult
    index::Float64
    solvable::Bool
    used_fallback::Bool
    difference_constant::Float64
    difference_slope::Float64
    indifference_residual::Float64
end


"""
    lwz_approx_index(x, project_type; iterations=4, detailed=false, ...)

Implement Algorithm 1 of Liu, Weber, and Zhang (2024) after the mapping

    epsilon = 1-kappa, B = r, T = phi0, T∘varphi = phi1.

Their passive subsidy and this paper's active charge have the same numerical
index level because the two single-project objectives differ only by the
additive constant `lambda/(1-beta)`.

If the final affine indifference equation is numerically unsolvable, the
default fallback is the type-specific immediate expected reward `r*kappa*x`.
This is the appropriate extension of Liu et al.'s fallback to projects with
heterogeneous observation probabilities `kappa`.

Liu et al. write the fallback as `r*x`, but their observation-error probability
is common across projects, so the omitted common factor does not affect their
rankings. The option `fallback=:liu_paper` reproduces that literal printed
fallback for diagnostic purposes only.
"""
function lwz_approx_index(
    x::Real,
    p::BSFProjectType;
    iterations::Integer=4,
    denominator_atol::Real=1e-12,
    fallback::Symbol=:type_myopic,
    detailed::Bool=false
)
    xf = Float64(x)

    isfinite(xf) && 0.0 <= xf <= 1.0 ||
        throw(ArgumentError("x must be finite and lie in [0,1]."))

    iterations >= 0 ||
        throw(ArgumentError("iterations must be nonnegative."))

    denominator_atolf = Float64(denominator_atol)

    denominator_atolf >= 0.0 ||
        throw(ArgumentError("denominator_atol must be nonnegative."))

    fallback in (:type_myopic, :liu_paper) ||
        throw(ArgumentError(
            "fallback must be :type_myopic or :liu_paper."
        ))

    threshold = xf

    reset_value = _solve_lwz_affine_value(
        _p11(p),
        threshold,
        p,
        iterations
    )

    no_ack_value = _solve_lwz_affine_value(
        _phi1(xf, p),
        threshold,
        p,
        iterations;
        reset_value=reset_value
    )

    passive_value = _solve_lwz_affine_value(
        _phi0(xf, p),
        threshold,
        p,
        iterations;
        reset_value=reset_value
    )

    success_probability = p.kappa * xf

    active_constant =
        p.r * success_probability +
        p.beta * (
            success_probability * reset_value.constant +
            (1.0 - success_probability) * no_ack_value.constant
        )

    active_slope =
        p.beta * (
            success_probability * reset_value.slope +
            (1.0 - success_probability) * no_ack_value.slope
        )

    passive_constant = p.beta * passive_value.constant
    passive_slope = 1.0 + p.beta * passive_value.slope

    difference_constant = active_constant - passive_constant
    difference_slope = active_slope - passive_slope

    solvable =
        isfinite(difference_constant) &&
        isfinite(difference_slope) &&
        abs(difference_slope) > denominator_atolf

    used_fallback = !solvable

    fallback_index = if fallback === :type_myopic
        p.r * p.kappa * xf
    else
        # Literal fallback printed in Liu et al.; retained only for replication.
        p.r * xf
    end

    index = solvable ?
            -difference_constant / difference_slope :
            fallback_index

    isfinite(index) || begin
        index = fallback_index
        solvable = false
        used_fallback = true
    end

    residual = solvable ?
               difference_constant + difference_slope * index :
               NaN

    result = LWZIndexResult(
        index,
        solvable,
        used_fallback,
        difference_constant,
        difference_slope,
        residual
    )

    return detailed ? result : result.index
end


function _detect_tail_period(
    states::Vector{Float64};
    max_period::Int,
    atol::Float64,
    repetitions::Int=3
)
    max_period >= 1 ||
        throw(ArgumentError("max_period must be positive."))

    repetitions >= 2 ||
        throw(ArgumentError("repetitions must be at least two."))

    for period in 1:max_period
        required = repetitions * period

        length(states) >= required ||
            continue

        first_index = length(states) - required + 1
        reference = @view states[first_index:(first_index + period - 1)]
        maximum_error = 0.0

        for repetition in 2:repetitions
            lo = first_index + (repetition - 1) * period
            candidate = @view states[lo:(lo + period - 1)]
            maximum_error = max(
                maximum_error,
                maximum(abs.(candidate .- reference))
            )
        end

        if maximum_error <= atol
            return (
                period=period,
                maximum_error=maximum_error,
                cycle_values=copy(
                    @view states[(end - period + 1):end]
                )
            )
        end
    end

    return (
        period=0,
        maximum_error=Inf,
        cycle_values=Float64[]
    )
end


function _lwz_orbit_path_diagnostic(
    start::Float64,
    threshold::Float64,
    p::BSFProjectType,
    iterations::Int,
    orbit_steps::Int,
    max_period::Int,
    cycle_atol::Float64
)
    closure_states, closure_rows = _lwz_path(
        start,
        threshold,
        p,
        iterations
    )

    terminal_row = closure_rows[end]
    terminal_next_state = terminal_row.next_state
    terminal_gap = if isnothing(terminal_next_state)
        0.0
    else
        next_state = terminal_next_state::Float64
        abs(next_state - closure_states[end])
    end

    states = Float64[start]
    passive_crossing_steps = Int[]
    never_activates = false

    for _ in 1:orbit_steps
        crossing = _passive_first_crossing(
            states[end],
            threshold,
            p
        )

        if isnothing(crossing.steps)
            never_activates = true
            break
        end

        push!(
            passive_crossing_steps,
            crossing.steps::Int
        )

        push!(
            states,
            _phi1(crossing.crossing_state, p)
        )
    end

    periodicity = _detect_tail_period(
        states;
        max_period=max_period,
        atol=cycle_atol
    )

    crossing_cycle = if periodicity.period == 0 ||
                        length(passive_crossing_steps) < periodicity.period
        Int[]
    else
        copy(
            @view passive_crossing_steps[
                (end - periodicity.period + 1):end
            ]
        )
    end

    return (
        start=start,
        published_closure_state=closure_states[end],
        published_next_state=terminal_next_state,
        published_closure_gap=terminal_gap,
        never_activates=never_activates,
        detected_period=periodicity.period,
        period_maximum_error=periodicity.maximum_error,
        cycle_values=periodicity.cycle_values,
        crossing_cycle=crossing_cycle,
        states=states,
        passive_crossing_steps=passive_crossing_steps
    )
end


"""
    lwz_orbit_diagnostic(x, project_type; iterations=4, ...)

Diagnose the state recursion underlying Liu et al.'s Eq. (60) at threshold
`x`. The reported `published_closure_gap` compares `k_iterations` with
`k_(iterations+1)`, whose values are identified by the paper's closure
`V(k_(iterations+1)) = V(k_iterations)`. A detected tail period larger than
one shows that the recursion approaches a cycle rather than the scalar limit
used to motivate that closure.

The three paths correspond to the value functions initiated at `p11`,
`phi1(x)` (no ACK), and `phi0(x)` (passive), respectively.
"""
function lwz_orbit_diagnostic(
    x::Real,
    p::BSFProjectType;
    iterations::Integer=4,
    orbit_steps::Integer=80,
    max_period::Integer=16,
    cycle_atol::Real=1e-10
)
    xf = Float64(x)
    iterationsi = Int(iterations)
    orbit_stepsi = Int(orbit_steps)
    max_periodi = Int(max_period)
    cycle_atolf = Float64(cycle_atol)

    isfinite(xf) && 0.0 <= xf <= 1.0 ||
        throw(ArgumentError("x must be finite and lie in [0,1]."))

    iterationsi >= 0 ||
        throw(ArgumentError("iterations must be nonnegative."))

    orbit_stepsi >= iterationsi + 1 ||
        throw(ArgumentError(
            "orbit_steps must be at least iterations+1."
        ))

    max_periodi >= 1 ||
        throw(ArgumentError("max_period must be positive."))

    cycle_atolf >= 0.0 ||
        throw(ArgumentError("cycle_atol must be nonnegative."))

    return (
        threshold=xf,
        iterations=iterationsi,
        reset=_lwz_orbit_path_diagnostic(
            _p11(p),
            xf,
            p,
            iterationsi,
            orbit_stepsi,
            max_periodi,
            cycle_atolf
        ),
        no_ack=_lwz_orbit_path_diagnostic(
            _phi1(xf, p),
            xf,
            p,
            iterationsi,
            orbit_stepsi,
            max_periodi,
            cycle_atolf
        ),
        passive=_lwz_orbit_path_diagnostic(
            _phi0(xf, p),
            xf,
            p,
            iterationsi,
            orbit_stepsi,
            max_periodi,
            cycle_atolf
        )
    )
end


# ============================================================================
# Type-specific lookup tables and policy action selection
# ============================================================================

"""
Type-specific priority table. Linear interpolation is used only between grid
points; exact evaluators remain available for validation and local refinement.
"""
struct PriorityTable
    name::Symbol
    type_id::Int
    label::String
    xgrid::Vector{Float64}
    values::Vector{Float64}
    fallback_count::Int

    function PriorityTable(
        name::Symbol,
        type_id::Integer,
        label::AbstractString,
        xgrid::AbstractVector{<:Real},
        values::AbstractVector{<:Real},
        fallback_count::Integer=0
    )
        xx = Float64.(xgrid)
        yy = Float64.(values)

        length(xx) >= 2 ||
            throw(ArgumentError("A priority table needs at least two points."))

        length(xx) == length(yy) ||
            throw(DimensionMismatch(
                "A priority table's grid and values must have equal lengths."
            ))

        all(isfinite, xx) && all(isfinite, yy) ||
            throw(ArgumentError(
                "Priority-table grids and values must be finite."
            ))

        all(diff(xx) .> 0.0) ||
            throw(ArgumentError(
                "A priority table's grid must be strictly increasing."
            ))

        xx[1] == 0.0 && xx[end] == 1.0 ||
            throw(ArgumentError(
                "A priority table must cover [0,1] exactly."
            ))

        fallback_count >= 0 ||
            throw(ArgumentError("fallback_count must be nonnegative."))

        return new(
            name,
            Int(type_id),
            String(label),
            xx,
            yy,
            Int(fallback_count)
        )
    end
end


@inline function lookup_priority(table::PriorityTable, x::Real)
    xf = Float64(x)

    isfinite(xf) && 0.0 <= xf <= 1.0 ||
        throw(ArgumentError("x must be finite and lie in [0,1]."))

    xf == 0.0 && return table.values[1]
    xf == 1.0 && return table.values[end]

    right = searchsortedfirst(table.xgrid, xf)

    if table.xgrid[right] == xf
        return table.values[right]
    end

    left = right - 1
    xleft = table.xgrid[left]
    xright = table.xgrid[right]
    weight = (xf - xleft) / (xright - xleft)

    return muladd(
        weight,
        table.values[right] - table.values[left],
        table.values[left]
    )
end


function _default_grid(nx::Integer)
    nx >= 2 ||
        throw(ArgumentError("nx must be at least 2."))

    return collect(range(0.0, 1.0; length=Int(nx)))
end


function build_lagrangian_tables(
    plan::LagrangianPlan,
    callbacks::PCLCallbacks;
    nx::Integer=4001,
    labels::Union{Nothing,AbstractVector}=nothing
)
    xgrid = _default_grid(nx)
    ntypes = length(plan.types)

    if !isnothing(labels)
        length(labels) == ntypes ||
            throw(DimensionMismatch(
                "labels must have one entry per project type."
            ))
    end

    tables = PriorityTable[]

    for type_id in 1:ntypes
        values = [
            lagrangian_priority(x, type_id, plan, callbacks)
            for x in xgrid
        ]

        label = isnothing(labels) ?
                "type $type_id" :
                String(labels[type_id])

        push!(
            tables,
            PriorityTable(
                :lagrangian,
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


function build_lwz_tables(
    types::AbstractVector{BSFProjectType};
    nx::Integer=4001,
    iterations::Integer=4,
    denominator_atol::Real=1e-12,
    fallback::Symbol=:type_myopic,
    labels::Union{Nothing,AbstractVector}=nothing
)
    !isempty(types) ||
        throw(ArgumentError("types must be nonempty."))

    xgrid = _default_grid(nx)
    ntypes = length(types)

    if !isnothing(labels)
        length(labels) == ntypes ||
            throw(DimensionMismatch(
                "labels must have one entry per project type."
            ))
    end

    tables = PriorityTable[]

    for type_id in 1:ntypes
        p = types[type_id]
        values = Vector{Float64}(undef, length(xgrid))
        fallback_count = 0

        for (grid_index, x) in enumerate(xgrid)
            result = lwz_approx_index(
                x,
                p;
                iterations=iterations,
                denominator_atol=denominator_atol,
                fallback=fallback,
                detailed=true
            )

            values[grid_index] = result.index
            fallback_count += result.used_fallback
        end

        label = isnothing(labels) ?
                "type $type_id" :
                String(labels[type_id])

        push!(
            tables,
            PriorityTable(
                :lwz,
                type_id,
                label,
                xgrid,
                values,
                fallback_count
            )
        )
    end

    return tables
end


function _validate_tables(
    tables::AbstractVector{PriorityTable},
    ntypes::Integer
)
    length(tables) == ntypes ||
        throw(DimensionMismatch(
            "There must be exactly one priority table per type."
        ))

    for type_id in 1:ntypes
        tables[type_id].type_id == type_id ||
            throw(ArgumentError(
                "Priority tables must be stored in type-id order."
            ))
    end

    return nothing
end


function priority_vector(
    beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    tables::AbstractVector{PriorityTable}
)
    length(beliefs) == length(type_of) ||
        throw(DimensionMismatch(
            "beliefs and type_of must have equal lengths."
        ))

    _validate_tables(tables, length(tables))

    all(k -> 1 <= k <= length(tables), type_of) ||
        throw(ArgumentError("Every type id must index tables."))

    priorities = Vector{Float64}(undef, length(beliefs))

    @inbounds for project in eachindex(beliefs, type_of)
        priorities[project] = lookup_priority(
            tables[type_of[project]],
            beliefs[project]
        )
    end

    return priorities
end


"""
    select_priority_actions(priorities, M; positive_only=false, ...)

Return a Boolean action vector using deterministic project-label order for
exact ties. With `positive_only=true`, select at most `M` strictly positive
priorities (standard Lagrangian policy). Otherwise select exactly the largest
`M` priorities (LagF and Liu et al. policies).
"""
function select_priority_actions(
    priorities::AbstractVector{<:Real},
    M::Integer;
    positive_only::Bool=false,
    positive_tol::Real=0.0
)
    N = length(priorities)

    0 <= M <= N ||
        throw(ArgumentError("Require 0 <= M <= length(priorities)."))

    positive_tolf = Float64(positive_tol)

    positive_tolf >= 0.0 ||
        throw(ArgumentError("positive_tol must be nonnegative."))

    all(isfinite, priorities) ||
        throw(ArgumentError("All priorities must be finite."))

    eligible = if positive_only
        [i for i in eachindex(priorities) if priorities[i] > positive_tolf]
    else
        collect(eachindex(priorities))
    end

    sort!(eligible; by=i -> (-Float64(priorities[i]), i))

    number_selected = min(Int(M), length(eligible))
    actions = falses(N)

    @inbounds for position in 1:number_selected
        actions[eligible[position]] = true
    end

    return actions
end


function select_lagrangian_actions(
    beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    tables::AbstractVector{PriorityTable},
    M::Integer;
    forced_capacity::Bool=false,
    positive_tol::Real=0.0
)
    priorities = priority_vector(beliefs, type_of, tables)

    actions = select_priority_actions(
        priorities,
        M;
        positive_only=!forced_capacity,
        positive_tol=positive_tol
    )

    return (actions=actions, priorities=priorities)
end


function select_lwz_actions(
    beliefs::AbstractVector{<:Real},
    type_of::AbstractVector{<:Integer},
    tables::AbstractVector{PriorityTable},
    M::Integer
)
    priorities = priority_vector(beliefs, type_of, tables)

    actions = select_priority_actions(
        priorities,
        M;
        positive_only=false
    )

    return (actions=actions, priorities=priorities)
end


# ============================================================================
# Monotonicity diagnostics and plots
# ============================================================================

"""
Return numerical monotonicity diagnostics for a sampled priority function.

`n_violations` counts adjacent decreases satisfying

    values[i+1]-values[i] < -(atol + rtol*max(abs(values[i]),abs(values[i+1]))).

The minimum secant slope is also reported so results from different grids can
be compared meaningfully.
"""
function monotonicity_report(
    table::PriorityTable;
    atol::Real=1e-10,
    rtol::Real=1e-10
)
    atolf = Float64(atol)
    rtolf = Float64(rtol)

    atolf >= 0.0 ||
        throw(ArgumentError("atol must be nonnegative."))

    rtolf >= 0.0 ||
        throw(ArgumentError("rtol must be nonnegative."))

    differences = diff(table.values)
    spacings = diff(table.xgrid)
    slopes = differences ./ spacings
    tolerances = [
        atolf + rtolf * max(abs(table.values[i]), abs(table.values[i + 1]))
        for i in eachindex(differences)
    ]

    violations = findall(differences .< .-tolerances)
    worst_interval = argmin(differences)

    return (
        name=table.name,
        type_id=table.type_id,
        label=table.label,
        ngrid=length(table.xgrid),
        min_difference=differences[worst_interval],
        min_secant_slope=minimum(slopes),
        n_violations=length(violations),
        worst_x_left=table.xgrid[worst_interval],
        worst_x_right=table.xgrid[worst_interval + 1],
        worst_value_left=table.values[worst_interval],
        worst_value_right=table.values[worst_interval + 1],
        fallback_count=table.fallback_count,
        violation_indices=violations
    )
end


function monotonicity_reports(
    tables::AbstractVector{PriorityTable};
    atol::Real=1e-10,
    rtol::Real=1e-10
)
    return [
        monotonicity_report(table; atol=atol, rtol=rtol)
        for table in tables
    ]
end


"""
Plot one family of priority tables using monochrome line styles. The first two
types are shown as black solid and black densely dashed curves, respectively;
additional types cycle through dotted and dash-dotted patterns. Any sampled
downward steps beyond the specified tolerance are marked by black triangles at
their right endpoints.
"""
function plot_priority_tables(
    tables::AbstractVector{PriorityTable};
    title::AbstractString="",
    ylabel::AbstractString="priority",
    width::AbstractString="12cm",
    height::AbstractString="7.5cm",
    atol::Real=1e-10,
    rtol::Real=1e-10,
    show_zero_line::Bool=false
)
    !isempty(tables) ||
        throw(ArgumentError("tables must be nonempty."))

    axis = @pgf Axis(
        {
            width => width,
            height => height,
            xlabel => raw"$x$",
            ylabel => ylabel,
            title => title,
            xmin => 0,
            xmax => 1,
            grid => "major",
            "legend style" =>
                "{at={(1.02,1)},anchor=north west,draw=none}",
            "legend cell align" => "left"
        }
    )

    if show_zero_line
        push!(
            axis,
            @pgf Plot(
                {
                    "black" => nothing,
                    "densely dotted" => nothing,
                    "line width" => "0.5pt",
                    "forget plot" => nothing
                },
                PGFPlotsX.Table(x=[0.0, 1.0], y=[0.0, 0.0])
            )
        )
    end

    for (table_number, table) in enumerate(tables)
        style_number = mod1(table_number, 4)

        curve = if style_number == 1
            @pgf Plot(
                {
                    "black" => nothing,
                    "solid" => nothing,
                    "line width" => "0.75pt"
                },
                PGFPlotsX.Table(x=table.xgrid, y=table.values)
            )
        elseif style_number == 2
            @pgf Plot(
                {
                    "black" => nothing,
                    "densely dashed" => nothing,
                    "line width" => "0.75pt"
                },
                PGFPlotsX.Table(x=table.xgrid, y=table.values)
            )
        elseif style_number == 3
            @pgf Plot(
                {
                    "black" => nothing,
                    "dotted" => nothing,
                    "line width" => "0.75pt"
                },
                PGFPlotsX.Table(x=table.xgrid, y=table.values)
            )
        else
            @pgf Plot(
                {
                    "black" => nothing,
                    "dashdotted" => nothing,
                    "line width" => "0.75pt"
                },
                PGFPlotsX.Table(x=table.xgrid, y=table.values)
            )
        end

        push!(axis, curve)

        push!(axis, PGFPlotsX.LegendEntry(table.label))

        report = monotonicity_report(table; atol=atol, rtol=rtol)

        if report.n_violations > 0
            right_indices = report.violation_indices .+ 1

            push!(
                axis,
                @pgf Plot(
                    {
                        "only marks" => nothing,
                        "mark" => "triangle*",
                        "black" => nothing,
                        "mark size" => "1.5pt",
                        "forget plot" => nothing
                    },
                    PGFPlotsX.Table(
                        x=table.xgrid[right_indices],
                        y=table.values[right_indices]
                    )
                )
            )
        end
    end

    return axis
end


"""
Return separate PGFPlotsX axes for the Liu-Weber-Zhang approximate index and
the Lagrangian one-step advantage. Separate panels avoid suggesting that the
two vertical scales have the same interpretation.
"""
function plot_lwz_lagrangian_indices(
    lwz_tables::AbstractVector{PriorityTable},
    lagrangian_tables::AbstractVector{PriorityTable};
    atol::Real=1e-10,
    rtol::Real=1e-10,
    width::AbstractString="12cm",
    height::AbstractString="7.5cm"
)
    lwz_plot = plot_priority_tables(
        lwz_tables;
        title="Liu-Weber-Zhang four-iteration approximate index",
        ylabel=raw"$W_{\mathrm{LWZ},4}(x)$",
        width=width,
        height=height,
        atol=atol,
        rtol=rtol,
        show_zero_line=false
    )

    lagrangian_plot = plot_priority_tables(
        lagrangian_tables;
        title="Lagrangian one-step advantage",
        ylabel=raw"$d^*(x)$",
        width=width,
        height=height,
        atol=atol,
        rtol=rtol,
        show_zero_line=true
    )

    return (liu=lwz_plot, lagrangian=lagrangian_plot)
end


# ============================================================================
# Lightweight internal checks that do not require the notebook PCL callbacks
# ============================================================================

function benchmark_index_selfcheck()
    project = BSFProjectType(
        p01=0.10,
        rho=0.60,
        kappa=0.75,
        r=1.0,
        beta=0.95
    )

    xgrid = collect(range(0.0, 1.0; length=101))
    results = [
        lwz_approx_index(
            x,
            project;
            iterations=4,
            fallback=:type_myopic,
            detailed=true
        )
        for x in xgrid
    ]

    all(isfinite(result.index) for result in results) ||
        error("Self-check failed: a Liu index was nonfinite.")

    solvable_results = filter(result -> result.solvable, results)

    isempty(solvable_results) &&
        error("Self-check failed: every Liu indifference equation fell back.")

    maximum(abs(result.indifference_residual) for result in solvable_results) <=
        1e-8 ||
        error("Self-check failed: an indifference residual was too large.")

    # Deterministic project-label ordering at ties.
    tied_actions = select_priority_actions(
        [2.0, 2.0, 1.0, -1.0],
        2;
        positive_only=false
    )

    tied_actions == BitVector([true, true, false, false]) ||
        error("Self-check failed: deterministic tie-breaking is incorrect.")

    standard_actions = select_priority_actions(
        [2.0, -0.1, -0.2],
        2;
        positive_only=true
    )

    standard_actions == BitVector([true, false, false]) ||
        error("Self-check failed: the standard Lag sign rule is incorrect.")

    return (
        passed=true,
        n_lwz_points=length(results),
        n_lwz_fallbacks=count(result -> result.used_fallback, results),
        max_indifference_residual=maximum(
            abs(result.indifference_residual)
            for result in solvable_results
        )
    )
end


end # module
