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
    modvar_ids::Vector{UInt}   # List of module-level variable address in LLVM IR

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
    function MethodInfo(m::Core.Method, name::Symbol=Symbol(""), debug = false)
        # Extract the function and its argument types from method signature
        func = m.sig.parameters[1].instance
        arg_types = Tuple(m.sig.parameters[2:end])

        # Ensure the method is compiled before LLVM extraction
        precompile(func, arg_types)

        # Determine mangled name and fallback-friendly name
        mangled = m.name
        name = name === Symbol("") ? mangled : name

        # Extract LLVM IR and measure the time taken
        origin_llvm = emit_llvm(m)
        llvm_ir = extract_llvm(m, origin_llvm, false)
        debug && open(string(mangled)*".debug_ll", "w") do f
            write(f, origin_llvm)
        end

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
    globals = Tuple{UInt, ModVarInfo}[]  # List to store (pointer, info) pairs
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
        ptr = UInt(pointer_from_objref(val_obj))

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
    ptr_identity(p::Ptr{T}) -> T

Returns the object pointed to by pointer `p` using an identity LLVM call.
This is effectively a cast from `Ptr{T}` to `T`.

⚠️ This is low-level and assumes `p` points to a valid Julia heap-allocated object.
"""
@inline function _ptr_identity(p::Ptr{T})::T where {T}
    Base.llvmcall((
        """
        define i64 @main(i64 %ptr) #0 {
        entry:
            ret i64 %ptr
        }
        attributes #0 = { alwaysinline nounwind ssp uwtable }
        """, "main"), T, Tuple{Ptr{T}}, p)
end

"""
    recover_heap_object(addr::Integer) -> Any

Given a raw address (e.g. from `pointer_from_objref`), attempts to reconstruct
the original Julia object stored at that memory location.

This function inspects the memory layout:
- If the tag indicates a `String`, reconstruct it.
- If the tag seems to point to a valid heap-allocated `DataType`, rehydrate the object.
Returns `nothing` if the tag is not recognizable or unsupported.
"""
@inline function recover_heap_object(addr::Integer)::Any
    return recover_heap_object(Ptr{Nothing}(addr))
end

"""
    recover_heap_object(p::Ptr) -> Any

Low-level internal logic to reconstruct a Julia object from a raw pointer `p`.
This inspects the memory tag to determine the type of the object.

Used internally by `recover_heap_object`.
"""
@inline function recover_heap_object(p::Ptr)::Any
    # Read the tag ID located 8 bytes before the pointer (typical Julia layout)
    tag = unsafe_load(Ptr{UInt}(p)-8, 1) & ~0x000000000000000f

    if tag == 0xA0  # Tag for String
        return _ptr_identity(Ptr{String}(p))
    elseif tag > 0xFFFF  # Arbitrary threshold: likely a DataType pointer
        datatype_ptr = Ptr{DataType}(tag)
        T = unsafe_load(datatype_ptr)
        return unsafe_load(Ptr{T}(p))
    else
        return nothing  # Unknown or unsupported tag
    end
end


"""
    assemble_modinfo(config::Dict{String,Any}, method_map::IdDict{Core.Method,Symbol}, modvar_map::IdDict{UInt,ModVarInfo}, check_ir::Bool = true) -> IdDict{Module, ModuleInfo}

Constructs `ModuleInfo` objects that capture method-level (`MethodInfo`) and global variable (`ModVarInfo`) metadata within each Julia module.

Each entry in `method_map` is processed to generate a `MethodInfo` object containing LLVM IR and related properties. 
Similarly, each global variable entry in `modvar_map` is assigned to the appropriate module. 

# Arguments
- `config::Dict{String,Any}`: Configuration dictionary. Must include keys like `"debug"` and `"policy"`, controlling diagnostics and symbol filtering.
- `method_map::IdDict{Core.Method,Symbol}`: Maps Julia `Method` objects to their LLVM mangled symbol names.
- `modvar_map::IdDict{UInt,ModVarInfo}`: Maps raw pointer addresses (as `UInt`) to their corresponding global variable metadata.

# LLVM IR policy Behavior
- `:warn`: Emits a warning if non-static LLVM IR is found.
- `:strict`: Throws an error.
- `:strip`: Attempts to strip the specific GC-related IR allocations
- `:strip_all`: Attempts to strip all GC-related IR allocations.

# Returns
- An `IdDict{Module, ModuleInfo}` mapping each involved Julia `Module` to its assembled `ModuleInfo` representation, including static methods and module-level variables.
"""
function assemble_modinfo(config::Dict{String,Any}, method_map::IdDict{Core.Method,Symbol}, modvar_map::IdDict{UInt,ModVarInfo})::IdDict{Module,ModuleInfo}
    # load configurations from config
    debug = config["debug"]
    gc_policy = config["policy"]

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
        method_info = MethodInfo(method, mangled_name, debug)

        # check if the emited LLVM IR is static or try to strip all gc symbols
        if !is_static_code(method_info.llvm_ir)

            if gc_policy == :warn           
                @warn "Non-static LLVM IR detected in method $(method):\n$(method_info.llvm_ir)"
            elseif gc_policy == :strict
                error("Non-static LLVM IR detected in method $(method):\n$(method_info.llvm_ir)")
            elseif gc_policy == :strip
                ;
            elseif gc_policy == :strip_all
                # Attempt to strip GC-related code from IR
                method_info.llvm_ir = strip_gc_allocations(method_info.llvm_ir)
            else
                error("Invalid policy: `$(policy)`. Must be one of :warn, :strict, :strip, :strip_all.")
            end
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
                var_mod = modvar.mod

                # Ensure the module containing the global var has ModuleInfo
                if !haskey(modinfo_map, var_mod)
                    modinfo_map[var_mod] = ModuleInfo(var_mod)
                end
                var_minfo = modinfo_map[var_mod]

                # Collect the LLVM declaration and name for later substitution
                push!(llvm_decls, modvar.llvm_decl)
                push!(new_names, modvar.mangled)
                push!(var_minfo.modvars, modvar)
            else
                # Attempt to recover the global object using its address
                obj = recover_heap_object(var_id)
                if obj === nothing 
                    @warn("Failed to recover global variable with ID = $(var_id) for method: $(method)")
                else
                    modvars = modinfo_map[mod].modvars

                    # Generate a unique symbolic name and mangle it for LLVM IR usage
                    name = Symbol("_global_$(length(modvars))")
                    mangled_name = mangle_NS(name, mod)

                    # Generate the LLVM definition and declaration for this global variable
                    def_ir, decl_ir = make_modvar_def("@" * mangled_name, obj)
                    
                    # Create a ModVarInfo and register it
                    modvar = ModVarInfo(name, mod, mangled_name, def_ir, decl_ir)
                    modvar_map[var_id] = modvar

                    push!(llvm_decls, decl_ir)
                    push!(new_names, mangled_name)
                    push!(modvars, modvar)
                end
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
    length(content) == 0 && return 0

    if check
        old = isfile(filepath) ? read(filepath, String) : ""
        content == old && return 0
    end
     
    open(filepath, "w") do f
        write(f, content)
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
    substrs = Regex(raw"(@ijl_|inttoptr\s*\(i64\s*(\d+)\s*to\s*ptr\)|%pgcstack = )")    
    occursin(substrs, ir) && return false
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


