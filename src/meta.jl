"""
    ModVarInfo(name::String, mod::Module, mangled::String, llvm_def::String, llvm_decl::String)

Holds metadata for a module-level mutable variable (`ModVar`):

- `name::Symbol`        : Julia binding name
- `file::Symbol`        : file of mod-vars
- `mangled::String`     : LLVM mangled global name
- `llvm_def::String`    : LLVM IR global variable definition
- `llvm_decl::String`   : LLVM IR external declaration
"""
mutable struct ModVarInfo
    name::Symbol
    mod::Module
    mangled::String
    llvm_def::String
    llvm_decl::String
end
@inline Base.isless(a::ModVarInfo, b::ModVarInfo) = a.name < b.name
@inline Base.:(==)(a::ModVarInfo, b::ModVarInfo) = a.name == b.name && a.mod == b.mod

"""
    Base.show(io::IO, mi::ModVarInfo)

Pretty-print `ModVarInfo` to the given IO stream in a readable format.
"""
function Base.show(io::IO, mi::ModVarInfo)
    print(io, "ModVar: `", mi.name, "` from ", mi.mod)
end

"""
    MethodInfo(m::Core.Method)
    MethodInfo(m::Core.Method, name::Symbol())

A mutable struct that stores metadata and compiled LLVM IR information for a specific Julia method.

# Fields
- `name::Symbol`: A user-friendly name for the method. Defaults to the mangled name if not provided.
- `mangled::Symbol`: The internal compiler name of the method, used for LLVM IR lookup.
- `arg_types::Tuple`: A tuple of argument types (excluding the function type), derived from the method signature.
- `method::Core.Method`: The original Julia `Method` object
- `llvm_ir::String`: The LLVM IR code generated for the method, extracted as a string.
- `modvar_ids::Vector{Int}`: A list of module-level variable addresses (e.g., `jl_global#`) found in the LLVM IR.
"""
mutable struct MethodInfo
    name::Symbol              # Friendly name (or fallback to mangled name)
    mangled::Symbol           # Internal name used for LLVM IR lookup
    arg_types::Tuple          # Tuple of argument types (excluding function type)
    method::Core.Method       # The original method object
    llvm_ir::String           # Extracted LLVM IR code as string
    modvar_ids::Vector{Int}   # List of module-level variable address in LLVM IR

    """
    Create a `MethodInfo` instance by compiling the given method and extracting its
    LLVM IR and related metadata.

    # Arguments
    - `m::Core.Method`: The method from which metadata and IR will be extracted.
    - `name::Symbol`: (Optional) A custom name to assign. Defaults to the method's mangled name.

    # Behavior
    - Parses the method signature to extract the function and argument types.
    - Ensures the method is JIT-compiled via `precompile`.
    - Retrieves the LLVM IR as a string using `extract_llvm`.
    - Detects and collects any module-level variable references from the native code.
    """
    function MethodInfo(m::Core.Method, name::Symbol=Symbol(""))
        # Extract the function and its argument types from method signature
        func = m.sig.parameters[1].instance
        arg_types = Tuple(m.sig.parameters[2:end])

        # Ensure the method is compiled before LLVM extraction
        precompile(func, arg_types)

        # Determine mangled name and fallback-friendly name
        mangled = m.name
        name = name === Symbol("") ? mangled : name

        # Extract LLVM IR and measure the time taken
        llvm_ir = extract_llvm(m, emit_llvm(m), false)

        # Extract module-level variable IDs if present
        modvar_ids = occursin("@\"jl_global#", llvm_ir) ?
                     extract_modvars(emit_native(m)) : Int[]

        return new(name, mangled, arg_types, m, llvm_ir, modvar_ids)
    end
end
Base.isless(a::MethodInfo, b::MethodInfo) = a.name < b.name
Base.:(==)(a::MethodInfo, b::MethodInfo) = a.mangled == b.mangled

"""
    Base.show(io::IO, mi::MethodInfo)

Pretty-print `MethodInfo` to the given IO stream in a readable format.
"""
function Base.show(io::IO, mi::MethodInfo)
    print(io, "Method: ", mi.name, mi.argv)
end

"""
    collect_modvars(mod::Module) -> Vector{Tuple{Int, ModVarInfo}}

Recursively collects all mutable, constant global variables defined in a Julia module `mod` 
(excluding functions, types, and strings), and returns a list of `(pointer, ModVarInfo)` pairs.

Each `ModVarInfo` contains:
- the original symbol name
- the module it belongs to
- its mangled LLVM symbol name
- its LLVM IR definition and declaration
"""
function collect_modvar_pairs(mod::Module)
    globals = Tuple{Int, ModVarInfo}[]  # List to store (pointer, info) pairs
    # file_path_sym = nothing             # Cache file path symbol to avoid repeated lookups

    for name in names(mod; all=true, imported=false)
        # Skip: undefined bindings, non-constants, and compiler-generated names
        isdefined(mod, name) || continue
        isconst(mod, name)   || continue
        startswith(String(name), "#") && continue

        val_obj = getfield(mod, name)

        # Skip: functions, types, and submodules (but recurse into non-self submodules)
        if val_obj isa Module
            val_obj !== mod && append!(globals, collect_modvar_pairs(val_obj))
            continue
        elseif val_obj isa Function || val_obj isa DataType
            continue
        end

        # We're only interested in mutable constant Ref-like objects
        ismutable(val_obj) || continue
        val_obj isa Ref || continue  # Must be a Ref to access wrapped value
        value = val_obj[]
        isa(value, String) && continue  # Skip strings

        # Convert object to memory address for identification
        ptr = Int(pointer_from_objref(val_obj))

        # Generate mangled LLVM symbol and IR code
        mangled_name = mangle_NS(name, mod)
        def_ir, decl_ir = gen_llvm_ir_decl("@" * mangled_name, value)

        # Only compute source file path symbol once
        # file_path_sym === nothing && (file_path_sym = get_mod_filepath(mod))

        # Create and store ModVarInfo record
        info = ModVarInfo(name, mod, mangled_name, def_ir, decl_ir)
        push!(globals, (ptr, info))
    end

    return globals
end

"""
    collect_methods!(name_map::IdDict{Method, Symbol}, method::Method)

Recursively collect methods starting from `method`, ensuring all are precompiled
and mapped to mangled names. This function avoids use of global state by requiring
an explicit name map to be passed in.

# Arguments
- `method::Method`: The starting method to process.
- `name_map::IdDict{Method, Symbol}`: A dictionary to store original methods and their original names.

# Behavior
- Ensures the method is precompiled.
- Stores a mapping from the method to its mangled name.
- Recursively processes `Core.MethodInstance` objects found in `method.roots`.
"""
function collect_methods!(name_map::IdDict{Method,Symbol}, method::Method, verbose = false)
    haskey(name_map, method) && return  # Avoid reprocessing

    # Extract function and argument types
    println(method)
    func = method.sig.parameters[1].instance
    args = Tuple(method.sig.parameters[2:end])

    # Ensure the method is compiled
    precompile(func, args)

    verbose == true && println("load: ", method)
    # Mangle the name and store mapping
    mangled = Symbol(mangle_NS(method.name, method.module))
    name_map[method] = method.name
    method.name = mangled

    # Recursively gather methods from MethodInstances
    for obj in method.roots
        if obj isa Core.MethodInstance
            collect_methods!(name_map, obj.def, verbose)
        end
    end
end

"""
    ModuleInfo

Stores metadata associated with a Julia `Module`, including referenced methods and 
global module-level variables.

# Fields
- `mod::Module`: The Julia module this information is associated with.
- `mangled::String`: The mangled name of the module, following the Itanium C++ ABI
- `modvars::IdSet{ModVarInfo}`: A set of global static variables (`ModVarInfo`) used in this module.
  Identity-based (`IdSet`) to ensure uniqueness by object reference.
- `methods::Vector{MethodInfo}`: A list of methods (`MethodInfo`) defined or referenced within this module.

# Usage
`ModuleInfo` is typically constructed internally during code analysis or code generation workflows
to track both method definitions and global state referenced by a module.
"""
struct ModuleInfo
    mod::Module                    # Symbolic file path or name
    mangled::String                # Mangled name of module
    modvars::IdSet{ModVarInfo}     # Used modvars using the address as the hash source (unique)
    methods::Vector{MethodInfo}    # Used methods
end
Base.isless(a::ModuleInfo, b::ModuleInfo) = Symbol(a.mod) < Symbol(b.mod)
Base.:(==)(a::ModuleInfo, b::ModuleInfo) = a.mod == b.mod

ModuleInfo(mod::Module) = ModuleInfo(mod, mangle_NS(Symbol("__MOD__"), mod), IdSet{ModVarInfo}(), MethodInfo[])
"""
    Base.show(io::IO, mi::ModuleInfo)

Pretty-print `ModuleInfo` to the given IO stream in a readable format.
"""
function Base.show(io::IO, mi::ModuleInfo)
    print(io, "Module `", mi.mod, "`: $(length(mi.modvars)) modvar, $(length(mi.methods)) methods")
end

"""
    assemble_modinfo(method_map::IdDict{Core.Method,Symbol}, modvar_map::IdDict{Int,ModVarInfo}, check_ir::Bool = true)::IdDict{Module,ModuleInfo}

Assembles `ModuleInfo` objects that contain information about both methods and associated module-level variables (`MethodInfo`) within each module.
During the assembly process, metadata for each method is generated as a `MethodInfo` object, including its LLVM IR representation.
If `MethodInfo` is set to true, the LLVM IR is optionally validated to ensure it represents static code only.

# Arguments
- `method_map`: A dictionary mapping `Method` objects to their mangled names.
- `modvar_map`: A dictionary mapping module variable pointer address to their `ModVarInfo` (module variable info).
- `check_ir`: If true, validates that LLVM IR of the method does not contain dynamic symbols.

# Returns
- A dictionary mapping each involved `Module` to its `ModuleInfo`.
"""
function assemble_modinfo(method_map::IdDict{Core.Method,Symbol}, modvar_map::IdDict{Int,ModVarInfo}, check_ir::Bool = true)::IdDict{Module,ModuleInfo}
     # Initialize an empty dictionary to hold ModuleInfo for each Module
    modinfo_map = IdDict{Module,ModuleInfo}()

    # n = length(method_map)
    # p = Progress(n; dt=n<100 ? 1000 : 1, desc="assembe methods...", barglyphs=BarGlyphs("[=> ]"), barlen=50)

    # Iterate over all methods and their mangled names
    for (method, mangled_name) in method_map
        mod = method.module

        # Create a new ModuleInfo if this module is not already registered
        if !haskey(modinfo_map, mod)
            modinfo_map[mod] = ModuleInfo(mod)
        end

        minfo = modinfo_map[mod]

        # Create MethodInfo for this method
        method_info = MethodInfo(method, mangled_name)

        # Optionally check if the method's LLVM IR is "static"
        if check_ir && !is_static_code(method_info.llvm_ir)
            error("find non-statice LLVM code from $(method):\n  $(method_info.llvm_ir)")
        end

        # Register the method in the module's method list
        push!(minfo.methods, method_info)


        # Prepare to patch global variables used by this method
        new_names = String[]       # Holds the mangled names
        llvm_decls = String[]      # Holds LLVM declarations of global variables

        # Process all global variables referenced by this method
        for var_id in method_info.modvar_ids
            if haskey(modvar_map, var_id)
                modvar = modvar_map[var_id]
                my_mod = modvar.mod

                # Ensure the module containing the global var has ModuleInfo
                if !haskey(modinfo_map, my_mod)
                    modinfo_map[my_mod] = ModuleInfo(my_mod)
                end
                my_minfo = modinfo_map[my_mod]

                # Collect the LLVM declaration and name for later substitution
                push!(llvm_decls, modvar.llvm_decl)
                push!(new_names, modvar.mangled)
                push!(my_minfo.modvars, modvar)
            else
                error("Cannot find global static variable for $(method) with ID $(var_id)")
            end
        end

        # Combine LLVM declarations and apply global variable names replacements in method IR
        method_info.llvm_ir = join(llvm_decls) * replace_globals(method_info.llvm_ir, new_names)
        # next!(p)
    end

    return modinfo_map
end

"""
    write_if_changed(filepath::String, content::String, check::Bool)::Int

Writes `content` to `filepath` only if the file content has changed or doesn't exist.
If `check` is false, no writing occurs.

# Returns
- 1 if the file was written (or would be written).
- 0 if no writing was done due to `check == false`.
"""
@inline function write_if_changed(filepath::String, content::String, check::Bool)::Int
    # If check is false, skip writing
    check || return 0

    # Read old content if file exists
    old = isfile(filepath) ? read(filepath, String) : ""

    # Only write if content has changed
    if content != old
        open(filepath, "w") do f
            write(f, content)
        end
    end
    return 1
end

"""
    is_static_code(ir::String)::Bool

Determines whether the given LLVM IR string is "static", i.e., free from dynamic symbols or Julia internal functions.

# Returns
- `true` if the IR contains no known dynamic patterns.
- `false` if any non-static signature (like `@ijl_`) is found.
"""
function is_static_code(ir::String)::Bool
    substrs = [" @ijl_",]
    any(s -> occursin(s, ir), substrs)  && return false
    return true
end

"""
    dump_llvm_ir(modinfo::ModuleInfo, output_dir::String, check::Bool)

Write LLVM IR files for a given `ModuleInfo` instance.
- Writes the IR of static module variables into one file named after the module.
- Writes the IR for each method individually into separate files.
- Skips writing files if content is unchanged (if `check` is true).
"""
function dump_llvm_ir(modinfo::ModuleInfo, output_dir::String, check::Bool)
    # Write module variable IR to a single .ll file
    modvar_path = joinpath(output_dir, String(modinfo.mangled) * ".ll")
    modvar_ir = join(v.llvm_def for v in modinfo.modvars)
    n = write_if_changed(modvar_path, modvar_ir, check)

    # Write each method's IR into its own file
    for m in modinfo.methods
        method_path = joinpath(output_dir, String(m.mangled) * ".ll")
        write_if_changed(method_path, m.llvm_ir, check)
    end
    return n + length(modinfo.methods)
end


