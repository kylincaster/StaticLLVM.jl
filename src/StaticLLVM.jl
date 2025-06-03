module StaticLLVM

using InteractiveUtils
using ArgParse
using ProgressMeter

export make

include("utils.jl")
include("extract.jl")
include("mangling.jl")
include("meta.jl")

"""
    _parse_args() -> Dict

    parse arguments
"""
function _parse_args()
    s = ArgParseSettings()
    s.description = "A tool for compile Julia files or packages into LLVM IR files."
    s.epilog = """Example usage:
  julia make.jl MyFile.jl --package MyPkg --dir out
  julia make.jl MyPkg --dir build
  """

    @add_arg_table s begin
        "--dir"
        help = "Directory for output files (optional)"
        default = "build"

        "--module"
        help = "Module name (default by `file`)"
        default = ""

        "--firstN"
        help = "print first N items (default = 0)"
        default = 0
        arg_type = Int

        "file"
        help = "Input: a Julia file, a project folder, or a registered package name"
        required = true
    end

    return parse_args(ARGS, s)
end

"""
    load_pkg() -> Module

Load a Julia package or source file specified by the first command-line argument (`ARGS[1]`).

# Behavior
- If `ARGS[1]` is a file path, includes the file and extracts the package name from the filename.
- Otherwise, attempts to `import` the package by name.
- If import fails and a directory with the package name exists, tries to include the source file under `./<package>/src/<package>`.
- Raises an error if the package cannot be found or loaded.
- Optionally, uses `ARGS[2]` as the module name to return; defaults to the package name.

# Returns
- The loaded Julia module.

# Notes
- Depends on global `ARGS` array (command line arguments).
- Prints status messages indicating loading steps.

# Example
```bash
julia script.jl MyPackage OptionalModuleName
"""
function load_pkg(config::Dict{String,Any})::Module
    pkg_arg = config["file"]
    pkg_arg_alias = endswith(pkg_arg, ".jl") ? pkg_arg[1:end-3] : pkg_arg
    if isdefined(Main, Symbol(pkg_arg_alias))
        println("Find package: ", pkg_arg_alias)
        return getfield(Main, Symbol(pkg_arg_alias))
    elseif isdefined(Main, Symbol(pkg_arg_alias * ".jl"))
        println("Find package: ", pkg_arg_alias * ".jl")
        return getfield(Main, Symbol(pkg_arg_alias + ".jl"))
    else
        try
            @eval import $(Symbol(pkg_arg_alias))
            println("Imported package: ", pkg_arg)
            return getfield(Main, Symbol(pkg_arg_alias))
        catch
            if isfile(pkg_arg)
                include(pkg_arg)
                work_dir, file_name = splitdir(pkg_arg)
                println("Included file from: ", pkg_arg)
                pkg_name, _ = splitext(file_name)
            else
                src_file = joinpath(pkg_arg, "src", pkg_arg * ".jl")
                include(src_file)
                println("Included package file from: ", src_file)
            end
            mod_name = length(config["module"]) > 1 ? config["module"] : pkg_arg
        end
    end

    # Return the module object by its symbol name
    return getfield(Main, Symbol(mod_name))
end

function make(mod::Module=Main)
    t_start = time()
    if mod === Main
        config = _parse_args()
        root_mod = load_pkg(config)
    else
        config = Dict("dir"=>"build", "firstN"=>0)
        root_mod = mod
    end

    # modvar_map = IdDict{Int, ModVar}, map between the address and modvar
    t0 = time()
    modvar_map = IdDict(p[1] => p[2] for p in collect_modvar_pairs(root_mod))
    dt = round(time() - t0; digits = 4)
    n = length(modvar_map)
    println("Collect $(n) global variables for $(dt) sec.")

    for (i, v) in enumerate(values(modvar_map))
        i > config["firstN"] && break
        println("  $i ", v)
    end


    t0 = time()
    # methods to origianl name
    method_map = IdDict{Core.Method, Symbol}()

    mt = which(root_mod._main_, (Int, Ptr{Ptr{UInt8}}))
    mt.name = :main
    collect_methods!(method_map, mt)
    mt.name = :main

    dt = round(time() - t0; digits = 4)
    println("\nCollect $(n) methods for $(dt) sec.")
    for (i, v) in enumerate(keys(method_map))
        i > config["firstN"] && break
        println("  $i ", v)
    end

    t0 = time()
    # IdDict{Module, ModuleInfo}
    modinfo_map = assemble_modinfo(method_map, modvar_map)
    dt = round(time() - t0; digits = 4)
    println("\nAssemble $(n) module for $(dt) sec.")

    path = config["dir"]
    if !isdir(path)
        mkpath(path)
    end

    print("write LLVM IR to `$(path)`\n")
    n = 0
    for (i, mod) in enumerate(values(modinfo_map))
        print("  $(i)th dump code from $(mod)\n")
        n += dump_llvm_ir(mod, path, true)
    end

    dt = round(time() - t_start; digits = 4)
    print("generate all LLVM IR files into `$(path)` for $(dt) sec with $(n) ll files.\n")
end

end # module end