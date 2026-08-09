# Run this with include(...) in the SAME initialized Jupyter kernel used for
# the clean_benchmark_v4 experiments. It records the active Julia environment
# without adding, removing, updating, or instantiating packages.

using Pkg
using InteractiveUtils
using LinearAlgebra
using SHA
using Dates

const REPO = get(
    ENV,
    "PAPER_PCL_SENSING_ERRORS_REPO",
    raw"C:\Users\JNINO\Documents\GitHub\paperPCLsensingErrors"
)
const OUT = joinpath(
    REPO,
    "reproducibility",
    "provenance",
    "julia_environment_used"
)

isdir(REPO) || error("Repository directory not found: $REPO")
mkpath(OUT)

csv_escape(x) = "\"" * replace(x === nothing ? "" : string(x), "\"" => "\"\"") * "\""
field_or(x, s::Symbol, default="") = hasproperty(x, s) ? getproperty(x, s) : default

open(joinpath(OUT, "julia_runtime_information.txt"), "w") do io
    println(io, "Captured: ", Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
    println(io, "Julia VERSION: ", VERSION)
    println(io, "Base.active_project(): ", Base.active_project())
    println(io, "Threads.nthreads(): ", Threads.nthreads())
    println(io, "BLAS.get_num_threads(): ", BLAS.get_num_threads())
    println(io, "Sys.KERNEL: ", Sys.KERNEL)
    println(io, "Sys.ARCH: ", Sys.ARCH)
    println(io, "Sys.CPU_NAME: ", Sys.CPU_NAME)
    println(io, "DEPOT_PATH:")
    foreach(x -> println(io, "  ", x), DEPOT_PATH)
    println(io, "LOAD_PATH:")
    foreach(x -> println(io, "  ", x), LOAD_PATH)
    println(io, "\nversioninfo(verbose=true):")
    versioninfo(io; verbose=true)
end

open(joinpath(OUT, "julia_pkg_status.txt"), "w") do io
    println(io, "Active project: ", Base.active_project(), "\n")
    println(io, "Pkg.status(mode=PKGMODE_PROJECT):")
    try
        Pkg.status(; io=io, mode=Pkg.PKGMODE_PROJECT)
    catch err
        println(io, "FAILED: ", sprint(showerror, err))
    end
    println(io, "\nPkg.status(mode=PKGMODE_MANIFEST):")
    try
        Pkg.status(; io=io, mode=Pkg.PKGMODE_MANIFEST)
    catch err
        println(io, "FAILED: ", sprint(showerror, err))
    end
end

deps = Pkg.dependencies()
open(joinpath(OUT, "julia_dependencies.csv"), "w") do io
    headers = ("uuid", "name", "version", "is_direct_dep", "is_stdlib", "is_tracking_path", "path", "git_source", "git_revision", "tree_hash")
    println(io, join(csv_escape.(headers), ","))
    ordered = sort(collect(deps); by=p -> (lowercase(string(field_or(last(p), :name, ""))), string(first(p))))
    for (uuid, info) in ordered
        version = field_or(info, :version, "")
        tree_hash = field_or(info, :tree_hash, "")
        row = (
            uuid,
            field_or(info, :name, ""),
            version === nothing ? "" : version,
            field_or(info, :is_direct_dep, false),
            field_or(info, :is_stdlib, false),
            field_or(info, :is_tracking_path, false),
            field_or(info, :path, ""),
            field_or(info, :git_source, ""),
            field_or(info, :git_revision, ""),
            tree_hash === nothing ? "" : tree_hash
        )
        println(io, join(csv_escape.(row), ","))
    end
end

copied = String[]
active_project = Base.active_project()
if active_project !== nothing && isfile(active_project)
    project_copy = joinpath(OUT, "Project_used.toml")
    cp(active_project, project_copy; force=true)
    push!(copied, project_copy)

    envdir = dirname(active_project)
    for (source_name, target_name) in (
        ("Manifest.toml", "Manifest_used.toml"),
        ("LocalPreferences.toml", "LocalPreferences_used.toml")
    )
        source_path = joinpath(envdir, source_name)
        if isfile(source_path)
            target_path = joinpath(OUT, target_name)
            cp(source_path, target_path; force=true)
            push!(copied, target_path)
        end
    end
end

open(joinpath(OUT, "environment_capture_summary.txt"), "w") do io
    println(io, "Julia environment capture completed.")
    println(io, "Captured: ", Dates.format(now(), dateformat"yyyy-mm-ddTHH:MM:SS"))
    println(io, "Repository: ", REPO)
    println(io, "Output directory: ", OUT)
    println(io, "Active project: ", Base.active_project())
    println(io, "Julia version: ", VERSION)
    println(io, "Julia threads: ", Threads.nthreads())
    println(io, "BLAS threads: ", BLAS.get_num_threads())
    println(io, "Copied active-environment files:")
    isempty(copied) ? println(io, "  none") : foreach(x -> println(io, "  ", x), copied)
    println(io, "\nNo package was added, removed, updated, or instantiated.")
end

files = sort(filter(name -> isfile(joinpath(OUT, name)) && name != "julia_environment_capture_sha256.csv", readdir(OUT)))
open(joinpath(OUT, "julia_environment_capture_sha256.csv"), "w") do io
    println(io, "\"File\",\"Length\",\"SHA256\"")
    for name in files
        path = joinpath(OUT, name)
        digest = uppercase(bytes2hex(open(SHA.sha256, path)))
        println(io, csv_escape(name), ",", filesize(path), ",", csv_escape(digest))
    end
end

println("Julia environment capture completed.")
println("Output directory: ", OUT)
println("Active project: ", Base.active_project())
println("Julia version: ", VERSION)
println("Julia threads: ", Threads.nthreads())
