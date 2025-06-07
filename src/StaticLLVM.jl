module StaticLLVM

using InteractiveUtils
using ArgParse
using ProgressMeter

export build

include("utils.jl")
include("extract.jl")
include("mangling.jl")
include("meta.jl")

# Default configuration for LLVM compilation and module processing
const DEFAULT_CONFIG = Dict{String,Any}(
    "dir" => "build",                                   # Directory to save generated LLVM IR files
    "module" => "",                                     # Module name (autofilled if empty)
    "compile_mode" => :none,                            # Compilation strategy: :none, :onefile, or :makefile
    "firstN" => 0,                                      #  Number of methods or items to print for debugging
    "clean_cache" => false,                             # Whether to clean the build/cache directory before compilation
    "clang" => "clang",                                 # Path to the clang compiler
    "cflag" => "-O3 -g -Wall -Wno-override-module",     # Flags passed to clang for optimization and warnings
    "debug" => false,                                   # Print debug information and write original LLVM IR representation as .debug_level
    "policy" => :warn                                   # policy for handling GC-influenced LLVM code: :warn, :strict, :strip, :strip_all
)

"""
    get_config(; kwargs...) -> Dict{String, Any}

Return a copy of the default config, with optional keyword overrides.
"""
function get_config(; kwargs...)::Dict{String,Any}
    config = copy(DEFAULT_CONFIG)
    for (k, v) in kwargs
        config[String(k)] = v
    end
    return config
end

"""
    clean_cache(path::String)

Delete cached build files (e.g., .o, .so, .dll, .lib, .a, .dylib) under the given directory.
This is useful for cleaning intermediate or compiled files before a fresh build.

# Arguments
- `path`: Directory where cache files are stored.
"""
function clean_cache(path::String)
    if !isdir(path)
        @warn "Path `$path` does not exist or is not a directory."
        return
    end

    # Define all file extensions to remove
    obj_ext = [".o"]
    static_lib_ext = [".a", ".lib"]
    dynamic_lib_ext = Sys.iswindows() ? [".dll"] :
                      Sys.isapple() ? [".dylib"] :
                      [".so"]

    exts = Set(vcat(obj_ext, static_lib_ext, dynamic_lib_ext))

    files = readdir(path; join=true)
    removed = 0

    for file in files
        ext = lowercase(splitext(file)[end])
        if ext in exts
            rm(file; force=true)
            #println("  Removed: $file")
            removed += 1
        end
    end

    println("Removed $removed cache file(s) in `$path`.")
end


"""
    function to parse arguments without a Module specified 
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
        default = "makefile.toml"
    end

    return parse_args(ARGS, s)
end


"""
    run_command(cmd::Cmd; verbose::Bool=false) -> NamedTuple

Run the given command and capture its output.

# Arguments
- `cmd`: A `Cmd` object representing the system command to execute.
- `verbose`: If true, prints the command before execution.

# Returns
A named tuple `(success, code, output)`:
- `success`: `true` if the command succeeded, `false` otherwise.
- `code`: Exit code (0 if success, -1 if error caught).
- `output`: Command output or error message as a string.
"""
function run_command(cmd::Cmd; verbose::Bool=false)
    verbose && println(cmd)
    try
        output = read(cmd, String)
        return (success=true, code=0, output=output)
    catch err
        return (success=false, code=-1, output=sprint(showerror, err))
    end
end

"""
    compile_llvm_files(config::Dict)

Compile all LLVM IR files in a specified directory into a single output binary.

# Expected keys in `config`:
- `"module"`: Name of the output executable.
- `"dir"`: Directory containing `.ll` files.
- `"clang"`: Path to `clang` compiler.
- `"cflag"`: Compiler flags (as a single string, e.g. "-O2 -flto").

Prints status messages and compilation result.
"""
function compile_llvm_files(config::Dict)
    # Extract configuration
    output_name = config["module"]
    source_dir = config["dir"]
    clang_path = config["clang"]
    flags = split(config["cflag"])  # Convert flag string to array

    source_files = joinpath(source_dir, "*.ll")

    println("Compiling all LLVM IR files in `$source_dir` into `$output_name`...")

    # Construct the command
    cmd = Cmd([clang_path, flags..., source_files, "-o", output_name])

    # Execute and handle result
    result = run_command(cmd; verbose=true)
    if result.success
        println("Successfully built `$output_name`.")
        clean_cache(source_dir)
    else
        println("Failed to compile `$output_name`: ", result.output)
    end
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

"""
    build(mod::Module=Main, config::Dict=default_config())

Main build process:
- Parse arguments if called from `Main`.
- Collect global variables and method info.
- Dump LLVM IR files.
- Optionally compile with clang.

# Arguments
- `mod`: The module to process (defaults to `Main`).
- `config`: Build configuration dictionary.

# Supported compile modes:
- `:none` – Just generate IR
- `:onefile` – Compile all IR into a single binary
- `:makefile` – (Not implemented)
"""
function build(mod::Module=Main, config::Dict{String,Any}=get_config())
    is_debug = config["debug"]
    t_start = time()

    # Step 1: Module loading and module name detection
    root_mod = mod
    if mod === Main
        config = merge!(config, _parse_args())
        root_mod = load_pkg(config)
    else
        if isempty(get(config, "module", ""))
            name = string(mod)
            config["module"] = startswith(name, "Main.") ? name[6:end] : name
        end
    end

    # Step 2: Collect global variables (modvar_map :: IdDict{Ptr, ModVar})
    t0 = time()
    modvars = collect_modvar_pairs(root_mod)
    modvar_map = IdDict(p[1] => p[2] for p in modvars)
    println("Collected $(length(modvar_map)) global variables in $(round(time() - t0, digits=4))s.")

    for (i, var) in enumerate(values(modvar_map))
        i > config["firstN"] && break
        println("  [$i] ", var)
    end

    # Step 3: Collect methods and rename `main` method
    t0 = time()
    method_map = IdDict{Core.Method,Symbol}()
    main_method = which(root_mod._main_, (Int, Ptr{Ptr{UInt8}}))
    main_method.name = :main
    collect_methods!(method_map, main_method)
    main_method.name = :main
    println("\nCollected $(length(method_map)) methods in $(round(time() - t0, digits=4))s.")

    for (i, m) in enumerate(keys(method_map))
        i > config["firstN"] && break
        println("  [$i] ", m)
    end

    # Step 4: Assemble module info (returns :: IdDict{Module, ModuleInfo})
    t0 = time()
    modinfo_map = assemble_modinfo(config, method_map, modvar_map)
    println("\nAssembled $(length(modinfo_map)) modules in $(round(time() - t0, digits=4))s.")

    # Step 5: Dump LLVM IR files
    out_dir = config["dir"]
    isdir(out_dir) || mkpath(out_dir)

    println("Writing LLVM IR files to `$(out_dir)`...")
    file_count = 0
    for (i, m) in enumerate(values(modinfo_map))
        println("  [$i] Dumping LLVM IR from module: $(m)")
        file_count += dump_llvm_ir(m, out_dir, true)
    end

    println("Generated $file_count LLVM IR file(s) into `$out_dir` in $(round(time() - t_start, digits=4))s.")

    # Step 6: Optionally compile
    compile_mode = config["compile_mode"]
    if compile_mode == :onefile
        compile_llvm_files(config)
    elseif compile_mode == :makefile
        error("compile_mode=:makefile is not implemented yet.")
    elseif compile_mode != :none
        error("Unknown compile_mode: $compile_mode. Use :none, :onefile, or :makefile.")
    end
end


end # module end