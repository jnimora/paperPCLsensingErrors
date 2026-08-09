using Base.Threads
using LinearAlgebra
using Statistics
using DataFrames
using CSV

BLAS.set_num_threads(1)

# ---------- helper grids ----------

cheb01(n::Integer) = (1 .- cos.(range(0, π; length=n))) ./ 2

function beta_grid(; nmid=5, nnear=7, δmin=1e-3, δmax=0.1)
    βmid = collect(range(0.2, 0.9; length=nmid))
    δnear = exp.(range(log(δmax), log(δmin); length=nnear))
    βnear = 1 .- δnear
    return unique(sort(vcat(βmid, βnear)))
end

function make_params(qgrid, αgrid, κgrid, βgrid)
    params = NamedTuple[]
    for q in qgrid, α in αgrid, κ in κgrid, β in βgrid
        ρ = α * (1 - q)
        push!(params, (q=q, ρ=ρ, κ=κ, β=β))
    end
    return params
end

# ---------- one-parameter-tuple scan ----------

function scan_one_tuple(; q, ρ, κ, β, Nx=21, Nu=21, ε=1e-10, endpoint_dense=true)
    x0v, x1v, _ = fixed_points(; q=q, ρ=ρ, κ=κ)

    xgrid = endpoint_dense ? cheb01(Nx) : collect(range(0.0, 1.0; length=Nx))
    ugrid = endpoint_dense ? cheb01(Nu) : collect(range(0.0, 1.0; length=Nu))

    δ = 1 - β
    min_slack = Inf
    xstar = NaN
    zstar = NaN

    for x in xgrid
        for u in ugrid
            z = x1v + u * (x0v - x1v)
            g = g_metric2(x, z; q=q, ρ=ρ, κ=κ, β=β, ε=ε)
            s = g - δ
            if s < min_slack
                min_slack = s
                xstar = x
                zstar = z
            end
        end
    end

    return (
        x0=x0v,
        x1=x1v,
        min_slack=min_slack,
        rel_slack=min_slack / δ,
        xstar=xstar,
        zstar=zstar,
    )
end

# ---------- threaded outer scan ----------

function threaded_scan(params; Nx=21, Nu=21, ε=1e-10, endpoint_dense=true)
    results = Vector{NamedTuple}(undef, length(params))

    Threads.@threads :dynamic for i in eachindex(params)
        p = params[i]
        s = scan_one_tuple(; p..., Nx=Nx, Nu=Nu, ε=ε, endpoint_dense=endpoint_dense)
        results[i] = merge(p, s)
    end

    return results
end

# ---------- pilot benchmark ----------

function pilot_benchmark(;
    Nq=3, Nα=3, Nκ=3,
    Nx=21, Nu=21,
    ε=1e-8,
    repeats=3,
    endpoint_dense=true,
    qmin=0.05, qmax=0.95,
    αmin=0.10, αmax=0.90,
    κmin=0.05, κmax=0.95,
    nβmid=3, nβnear=4,
    δmin=1e-2, δmax=0.1,
    csvfile=nothing,
)

    qgrid = collect(range(qmin, qmax; length=Nq))
    αgrid = collect(range(αmin, αmax; length=Nα))
    κgrid = collect(range(κmin, κmax; length=Nκ))
    βgrid = beta_grid(nmid=nβmid, nnear=nβnear, δmin=δmin, δmax=δmax)

    params = make_params(qgrid, αgrid, κgrid, βgrid)
    nevals = length(params) * Nx * Nu

    println("Threads.nthreads() = ", Threads.nthreads())
    println("Number of parameter tuples = ", length(params))
    println("Nx = ", Nx, ", Nu = ", Nu)
    println("Total g_metric2 evaluations per run = ", nevals)
    println("β grid = ", βgrid)

    # warmup
    println("\nWarmup run...")
    _ = threaded_scan(params; Nx=Nx, Nu=Nu, ε=ε, endpoint_dense=endpoint_dense)

    times = Float64[]
    last_res = nothing

    println("\nTimed runs:")
    for r in 1:repeats
        GC.gc()
        t = @elapsed last_res = threaded_scan(params; Nx=Nx, Nu=Nu, ε=ε, endpoint_dense=endpoint_dense)
        push!(times, t)
        println("  run ", r, ": ", round(t, digits=3), " s")
    end

    tbest = minimum(times)
    tmed = median(times)
    rate_best = nevals / tbest
    rate_med = nevals / tmed

    df = DataFrame(last_res)
    sort!(df, :min_slack)

    println("\nSummary")
    println("  best time   = ", round(tbest, digits=3), " s")
    println("  median time = ", round(tmed, digits=3), " s")
    println("  best eval/s = ", round(rate_best, digits=1))
    println("  med  eval/s = ", round(rate_med, digits=1))
    println("  worst min_slack = ", df.min_slack[1])
    println("  worst tuple:")
    println(df[1, [:q, :ρ, :κ, :β, :xstar, :zstar, :min_slack, :rel_slack]])

    if csvfile !== nothing
        CSV.write(csvfile, df)
        println("\nResults written to: ", csvfile)
    end

    stats = (
        threads=Threads.nthreads(),
        nparams=length(params),
        nevals=nevals,
        tbest=tbest,
        tmed=tmed,
        rate_best=rate_best,
        rate_med=rate_med,
        worst_min_slack=df.min_slack[1],
    )

    return df, stats
end