module PCLIBoundaryStressV1

using Base.Threads
using CSV
using DataFrames
using Dates
using Printf
using Statistics

export run_pcli_boundary_stress

function fixed_points(; p01::Float64, rho::Float64, kappa::Float64)
    x0 = p01 / (1.0 - rho)
    p11 = p01 + rho
    B = 1.0 - rho + kappa * p11
    disc = B^2 - 4.0 * kappa * p01
    disc > 0.0 || error("Nonpositive fixed-point discriminant: $disc")
    # The algebraically equivalent expression below avoids subtractive
    # cancellation in the boundary regimes with small p01 and kappa near one.
    x1 = (2.0 * p01) / (B + sqrt(disc))
    return x0, x1
end

function cheb01(n::Int)
    n >= 2 || throw(ArgumentError("grid size must be at least 2"))
    theta = range(0.0, pi; length=n)
    grid = (1.0 .- cos.(theta)) ./ 2.0
    grid[begin] = 0.0
    grid[end] = 1.0
    return grid
end

function padded_grid(x1::Float64, x0::Float64;
                     nmid::Int, nside::Int, pad_fraction::Float64)
    0.0 <= x1 <= x0 <= 1.0 || error("Invalid fixed points: x1=$x1, x0=$x0")
    gap = x0 - x1
    xleft = max(0.0, x1 - pad_fraction * gap)
    xright = min(1.0, x0 + pad_fraction * gap)

    left = nside > 0 && xleft < x1 ?
        collect(range(xleft, x1; length=nside + 1))[1:end-1] : Float64[]
    middle = collect(range(x1, x0; length=nmid))
    right = nside > 0 && x0 < xright ?
        collect(range(x0, xright; length=nside + 1))[2:end] : Float64[]

    xgrid = vcat(left, middle, right)
    i1 = length(left) + 1
    i0 = length(left) + length(middle)
    return xgrid, i1, i0, xleft, xright
end

parameter_key(p) = (Float64(p.p01), Float64(p.alpha),
                    Float64(p.kappa), Float64(p.beta))

function make_parameters(p01_grid, alpha_grid, kappa_grid, beta_grid)
    params = NamedTuple[]
    for p01_raw in p01_grid, alpha_raw in alpha_grid,
        kappa_raw in kappa_grid, beta_raw in beta_grid

        p01 = Float64(p01_raw)
        alpha = Float64(alpha_raw)
        kappa = Float64(kappa_raw)
        beta = Float64(beta_raw)
        rho = alpha * (1.0 - p01)
        p10 = (1.0 - alpha) * (1.0 - p01)

        0.0 < p01 < 1.0 || error("Invalid p01=$p01")
        0.0 < alpha < 1.0 || error("Invalid alpha=$alpha")
        0.0 < kappa < 1.0 || error("Invalid kappa=$kappa")
        0.0 < beta < 1.0 || error("Invalid beta=$beta")

        push!(params, (p01=p01, alpha=alpha, rho=rho, p10=p10,
                       kappa=kappa, beta=beta))
    end
    return params
end

function scan_pcli1(g_metric_fn, p;
                    nx::Int, nu::Int, epsilon::Float64)
    x0, x1 = fixed_points(p01=p.p01, rho=p.rho, kappa=p.kappa)
    xgrid = cheb01(nx)
    ugrid = cheb01(nu)
    zgrid = x1 .+ ugrid .* (x0 - x1)
    zgrid[begin] = x1
    zgrid[end] = x0

    min_slack = Inf
    min_g = Inf
    xstar = NaN
    zstar = NaN
    discount_gap = 1.0 - p.beta

    for x in xgrid, z in zgrid
        g = Float64(g_metric_fn(
            x, z;
            p01=p.p01, rho=p.rho, kappa=p.kappa,
            beta=p.beta, epsilon=epsilon
        ))
        isfinite(g) || error("Nonfinite g at $(merge(p, (x=x, z=z)))")
        slack = g - discount_gap
        if slack < min_slack
            min_slack = slack
            min_g = g
            xstar = x
            zstar = z
        end
    end

    return (
        pcli1_min_g=min_g,
        pcli1_min_slack=min_slack,
        pcli1_relative_slack=min_slack / discount_gap,
        pcli1_xstar=xstar,
        pcli1_zstar=zstar,
        x1=x1,
        x0=x0,
        pcli1_evaluations=nx * nu
    )
end

function scan_pcli2(fg_metric_fn, p;
                    nmid::Int, nside::Int,
                    pad_fraction::Float64,
                    epsilon::Float64)
    x0, x1 = fixed_points(p01=p.p01, rho=p.rho, kappa=p.kappa)
    xgrid, i1, i0, xleft, xright = padded_grid(
        x1, x0;
        nmid=nmid, nside=nside, pad_fraction=pad_fraction
    )

    n = length(xgrid)
    mvals = Vector{Float64}(undef, n)
    min_g_diag = Inf

    for i in eachindex(xgrid)
        x = xgrid[i]
        fg = fg_metric_fn(
            x, x;
            p01=p.p01, rho=p.rho, kappa=p.kappa,
            reward=1.0, beta=p.beta, epsilon=epsilon
        )
        f = Float64(fg[1])
        g = Float64(fg[2])
        isfinite(f) && isfinite(g) && g > 0.0 ||
            error("Invalid diagonal metrics at $(merge(p, (x=x, f=f, g=g)))")
        mvals[i] = f / g
        min_g_diag = min(min_g_diag, g)
    end

    differences = diff(mvals)
    spacings = diff(xgrid)
    slopes = differences ./ spacings

    j_all = argmin(differences)
    j_slope_all = argmin(slopes)
    core_range = i1:(i0 - 1)
    core_differences = @view differences[core_range]
    core_slopes = @view slopes[core_range]
    j_core_local = argmin(core_differences)
    j_slope_core_local = argmin(core_slopes)
    j_core = first(core_range) + j_core_local - 1
    j_slope_core = first(core_range) + j_slope_core_local - 1

    endpoint_steps = Float64[]
    i1 > 1 && push!(endpoint_steps, abs(mvals[i1] - mvals[i1 - 1]))
    i1 < n && push!(endpoint_steps, abs(mvals[i1 + 1] - mvals[i1]))
    i0 > 1 && push!(endpoint_steps, abs(mvals[i0] - mvals[i0 - 1]))
    i0 < n && push!(endpoint_steps, abs(mvals[i0 + 1] - mvals[i0]))

    return (
        pcli2_min_g_diag=min_g_diag,
        pcli2_min_diff_all=differences[j_all],
        pcli2_diff_all_xleft=xgrid[j_all],
        pcli2_diff_all_xright=xgrid[j_all + 1],
        pcli2_min_diff_core=differences[j_core],
        pcli2_diff_core_xleft=xgrid[j_core],
        pcli2_diff_core_xright=xgrid[j_core + 1],
        pcli2_min_slope_all=slopes[j_slope_all],
        pcli2_slope_all_xleft=xgrid[j_slope_all],
        pcli2_slope_all_xright=xgrid[j_slope_all + 1],
        pcli2_min_slope_core=slopes[j_slope_core],
        pcli2_slope_core_xleft=xgrid[j_slope_core],
        pcli2_slope_core_xright=xgrid[j_slope_core + 1],
        pcli2_endpoint_proxy=maximum(endpoint_steps),
        pcli2_xleft=xleft,
        pcli2_xright=xright,
        pcli2_evaluations=n
    )
end

function evaluate_parameter(g_metric_fn, fg_metric_fn, p;
                            nx::Int, nu::Int,
                            nmid::Int, nside::Int,
                            pad_fraction::Float64,
                            epsilon::Float64)
    first = scan_pcli1(g_metric_fn, p; nx=nx, nu=nu, epsilon=epsilon)
    second = scan_pcli2(
        fg_metric_fn, p;
        nmid=nmid, nside=nside,
        pad_fraction=pad_fraction, epsilon=epsilon
    )
    return merge(p, first, second)
end

function numerical_summary(coarse::DataFrame,
                           refined1::DataFrame,
                           refined2::DataFrame)
    rows = NamedTuple[]
    metrics = [
        ("coarse_pcli1_slack", coarse.pcli1_min_slack),
        ("coarse_pcli1_g", coarse.pcli1_min_g),
        ("coarse_pcli2_diff_core", coarse.pcli2_min_diff_core),
        ("coarse_pcli2_slope_core", coarse.pcli2_min_slope_core),
        ("coarse_pcli2_slope_all", coarse.pcli2_min_slope_all),
        ("refined_pcli1_slack", refined1.pcli1_min_slack),
        ("refined_pcli2_slope_core", refined2.pcli2_min_slope_core),
        ("refined_pcli2_slope_all", refined2.pcli2_min_slope_all)
    ]
    probabilities = [0.0, 0.01, 0.05, 0.10, 0.50]
    for (metric, values_raw) in metrics
        values = Float64.(values_raw)
        for probability in probabilities
            push!(rows, (
                metric=metric,
                quantile_probability=probability,
                value=quantile(values, probability)
            ))
        end
    end
    return DataFrame(rows)
end

function tolerance_counts(coarse::DataFrame)
    rows = NamedTuple[]
    for tolerance in (1e-10, 1e-8, 1e-6, 1e-4)
        push!(rows, (
            metric="pcli1_min_slack",
            tolerance=tolerance,
            count=count(x -> x <= tolerance, coarse.pcli1_min_slack),
            total=nrow(coarse)
        ))
        push!(rows, (
            metric="pcli1_relative_slack",
            tolerance=tolerance,
            count=count(x -> x <= tolerance, coarse.pcli1_relative_slack),
            total=nrow(coarse)
        ))
        push!(rows, (
            metric="pcli2_min_slope_core",
            tolerance=tolerance,
            count=count(x -> x <= tolerance, coarse.pcli2_min_slope_core),
            total=nrow(coarse)
        ))
        push!(rows, (
            metric="pcli2_min_slope_all",
            tolerance=tolerance,
            count=count(x -> x <= tolerance, coarse.pcli2_min_slope_all),
            total=nrow(coarse)
        ))
    end
    result = DataFrame(rows)
    result.fraction = result.count ./ result.total
    return result
end

"""
    run_pcli_boundary_stress(; g_metric_fn, fg_metric_fn, ...)

Run a resumable boundary-focused PCLI1/PCLI2 diagnostic. The callback
functions should be the notebook's existing `g_metric2` and `fg_metric2`,
passed through the short wrappers shown in the accompanying instructions.
"""
function run_pcli_boundary_stress(;
    g_metric_fn,
    fg_metric_fn,
    p01_grid=[1e-5, 1e-3, 0.05, 0.50, 0.95],
    alpha_grid=[0.50, 0.95, 0.99, 0.9999],
    kappa_grid=[0.50, 0.95, 0.99, 0.999],
    beta_grid=[0.90, 0.99, 0.995, 0.999],
    nx::Int=81,
    nu::Int=81,
    nmid::Int=2001,
    nside::Int=201,
    pad_fraction::Float64=0.05,
    epsilon::Float64=1e-8,
    refine_count::Int=20,
    nx_refine::Int=161,
    nu_refine::Int=161,
    nmid_refine::Int=8001,
    nside_refine::Int=401,
    chunk_size::Int=max(1, 2 * Base.Threads.nthreads()),
    max_new_cases::Union{Nothing,Int}=nothing,
    output_prefix::String="pcli_boundary_stress_v1"
)
    nx >= 2 && nu >= 2 || throw(ArgumentError("nx and nu must be at least 2"))
    nmid >= 2 || throw(ArgumentError("nmid must be at least 2"))
    nside >= 0 || throw(ArgumentError("nside must be nonnegative"))
    0.0 <= pad_fraction <= 1.0 ||
        throw(ArgumentError("pad_fraction must lie in [0,1]"))
    refine_count >= 1 || throw(ArgumentError("refine_count must be positive"))
    nx_refine >= nx && nu_refine >= nu ||
        throw(ArgumentError("refined PCLI1 grids must not be smaller than coarse grids"))
    nmid_refine >= nmid && nside_refine >= nside ||
        throw(ArgumentError("refined PCLI2 grids must not be smaller than coarse grids"))

    start_time = time()
    params = make_parameters(p01_grid, alpha_grid, kappa_grid, beta_grid)
    expected = length(params)
    expected_keys = Set(parameter_key(p) for p in params)
    coarse_file = output_prefix * "_coarse.csv"
    refined1_file = output_prefix * "_refined_pcli1.csv"
    refined2_file = output_prefix * "_refined_pcli2.csv"
    summary_file = output_prefix * "_quantiles.csv"
    tolerance_file = output_prefix * "_near_tolerance_counts.csv"
    check_file = output_prefix * "_check.csv"

    coarse = if isfile(coarse_file)
        loaded = CSV.read(coarse_file, DataFrame)
        required = [:p01, :alpha, :kappa, :beta]
        all(in(names(loaded)), string.(required)) ||
            error("Existing checkpoint has an incompatible schema")
        filter!(row -> (Float64(row.p01), Float64(row.alpha),
                        Float64(row.kappa), Float64(row.beta)) in expected_keys,
                loaded)
        unique!(loaded, [:p01, :alpha, :kappa, :beta])
        loaded
    else
        DataFrame()
    end

    completed_keys = isempty(coarse) ? Set{NTuple{4,Float64}}() :
        Set((Float64(row.p01), Float64(row.alpha),
             Float64(row.kappa), Float64(row.beta)) for row in eachrow(coarse))
    pending = [p for p in params if parameter_key(p) ∉ completed_keys]
    if max_new_cases !== nothing
        max_new_cases >= 0 || throw(ArgumentError("max_new_cases must be nonnegative"))
        pending = first(pending, min(max_new_cases, length(pending)))
    end

    new_cases = 0
    for first_index in 1:chunk_size:length(pending)
        last_index = min(first_index + chunk_size - 1, length(pending))
        block = pending[first_index:last_index]
        first_result = evaluate_parameter(
            g_metric_fn, fg_metric_fn, block[1];
            nx=nx, nu=nu, nmid=nmid, nside=nside,
            pad_fraction=pad_fraction, epsilon=epsilon
        )
        results = Vector{typeof(first_result)}(undef, length(block))
        results[1] = first_result

        Base.Threads.@threads :dynamic for i in 2:length(block)
            results[i] = evaluate_parameter(
                g_metric_fn, fg_metric_fn, block[i];
                nx=nx, nu=nu, nmid=nmid, nside=nside,
                pad_fraction=pad_fraction, epsilon=epsilon
            )
        end

        block_df = DataFrame(results)
        coarse = isempty(coarse) ? block_df : vcat(coarse, block_df; cols=:union)
        unique!(coarse, [:p01, :alpha, :kappa, :beta])
        sort!(coarse, [:p01, :alpha, :kappa, :beta])
        CSV.write(coarse_file, coarse)
        new_cases += length(block)

        @printf("[%s] completed %d/%d boundary tuples\n",
                Dates.format(now(), "HH:MM:SS"), nrow(coarse), expected)
    end

    complete = nrow(coarse) == expected
    refined1 = DataFrame()
    refined2 = DataFrame()
    quantiles = DataFrame()
    near_counts = DataFrame()

    if complete
        worst1 = first(sort(coarse, :pcli1_min_slack), min(refine_count, expected))
        rows1 = NamedTuple[]
        for row in eachrow(worst1)
            p = (p01=Float64(row.p01), alpha=Float64(row.alpha),
                 rho=Float64(row.rho), p10=Float64(row.p10),
                 kappa=Float64(row.kappa), beta=Float64(row.beta))
            push!(rows1, merge(p, scan_pcli1(
                g_metric_fn, p;
                nx=nx_refine, nu=nu_refine, epsilon=epsilon
            )))
        end
        refined1 = DataFrame(rows1)
        sort!(refined1, :pcli1_min_slack)
        CSV.write(refined1_file, refined1)

        worst2 = first(sort(coarse, :pcli2_min_slope_core),
                       min(refine_count, expected))
        rows2 = NamedTuple[]
        for row in eachrow(worst2)
            p = (p01=Float64(row.p01), alpha=Float64(row.alpha),
                 rho=Float64(row.rho), p10=Float64(row.p10),
                 kappa=Float64(row.kappa), beta=Float64(row.beta))
            push!(rows2, merge(p, scan_pcli2(
                fg_metric_fn, p;
                nmid=nmid_refine, nside=nside_refine,
                pad_fraction=pad_fraction, epsilon=epsilon
            )))
        end
        refined2 = DataFrame(rows2)
        sort!(refined2, :pcli2_min_slope_core)
        CSV.write(refined2_file, refined2)

        quantiles = numerical_summary(coarse, refined1, refined2)
        near_counts = tolerance_counts(coarse)
        CSV.write(summary_file, quantiles)
        CSV.write(tolerance_file, near_counts)
    end

    isempty(coarse) && error("No parameter tuple has been evaluated")

    pcli1_pass = all(x -> isfinite(x) && x >= -1e-9,
                     Float64.(coarse.pcli1_min_slack))
    pcli2_pass = all(x -> isfinite(x) && x >= -1e-8,
                     Float64.(coarse.pcli2_min_slope_all))
    g_positive = all(x -> isfinite(x) && x > 0.0,
                     Float64.(coarse.pcli1_min_g)) &&
                 all(x -> isfinite(x) && x > 0.0,
                     Float64.(coarse.pcli2_min_g_diag))

    refined_pcli1_minimum = complete ? minimum(refined1.pcli1_min_slack) : NaN
    refined_pcli2_core_minimum = complete ? minimum(refined2.pcli2_min_slope_core) : NaN
    refined_pcli2_all_minimum = complete ? minimum(refined2.pcli2_min_slope_all) : NaN
    refined_pcli1_pass = complete ?
        all(x -> isfinite(x) && x >= -1e-9,
            Float64.(refined1.pcli1_min_slack)) : missing
    refined_pcli2_pass = complete ?
        all(x -> isfinite(x) && x >= -1e-8,
            Float64.(refined2.pcli2_min_slope_all)) : missing

    check = DataFrame([(
        completed_parameter_tuples=nrow(coarse),
        expected_parameter_tuples=expected,
        new_parameter_tuples_this_run=new_cases,
        coarse_grid_complete=complete,
        all_pcli1_slacks_nonnegative=pcli1_pass,
        all_pcli2_secant_slopes_nonnegative=pcli2_pass,
        all_sampled_marginal_work_positive=g_positive,
        refined_pcli1_slacks_nonnegative=refined_pcli1_pass,
        refined_pcli2_secant_slopes_nonnegative=refined_pcli2_pass,
        minimum_pcli1_slack=minimum(coarse.pcli1_min_slack),
        minimum_pcli2_core_slope=minimum(coarse.pcli2_min_slope_core),
        minimum_pcli2_all_slope=minimum(coarse.pcli2_min_slope_all),
        refined_minimum_pcli1_slack=refined_pcli1_minimum,
        refined_minimum_pcli2_core_slope=refined_pcli2_core_minimum,
        refined_minimum_pcli2_all_slope=refined_pcli2_all_minimum,
        coarse_pcli1_evaluations=sum(coarse.pcli1_evaluations),
        coarse_pcli2_evaluations=sum(coarse.pcli2_evaluations),
        refined_pcli1_evaluations=complete ? sum(refined1.pcli1_evaluations) : 0,
        refined_pcli2_evaluations=complete ? sum(refined2.pcli2_evaluations) : 0,
        smallest_p10=minimum(coarse.p10),
        largest_rho=maximum(coarse.rho),
        julia_threads=Base.Threads.nthreads(),
        wall_minutes_this_run=(time() - start_time) / 60.0,
        checkpoint_file=coarse_file
    )])
    CSV.write(check_file, check)

    return (
        coarse=coarse,
        refined_pcli1=refined1,
        refined_pcli2=refined2,
        quantiles=quantiles,
        near_tolerance_counts=near_counts,
        check=check,
        check_file=check_file
    )
end

end # module
