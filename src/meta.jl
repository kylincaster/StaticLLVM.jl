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
"""
mutable struct MethodInfo
    name::Symbol              # Friendly name (or fallback to mangled name)
    mangled::Symbol           # Internal name used for LLVM IR lookup
    arg_types::Tuple          # Tuple of argument types (excluding function type)
    method::Core.Method       # The original method object
    llvm::LLVM_Meta           # Extracted LLVM IR meta Information
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
    function MethodInfo(m::Core.Method, name::Symbol=Symbol(""), debug::Bool= false, gc_policy::Symbol=:strict)
        # Extract the function and its argument types from method signature
        func = m.sig.parameters[1].instance
        arg_types = Tuple(m.sig.parameters[2:end])

        # Ensure the method is compiled before LLVM extraction
        precompile(func, arg_types)

        # Determine mangled name and fallback-friendly name
        mangled = m.name
        name = name === Symbol("") ? mangled : name

        # Extract LLVM IR and measure the time taken
        llvm_ir = if debug
            origin_llvm = emit_llvm(m; clean=false)
            open(string(mangled)*".debug_ll", "w") do f
                write(f, origin_llvm)
            end
            strip_comments(origin_llvm)
        else
            emit_llvm(m)
        end
        
        # check if the emited LLVM IR is static or try to strip all gc symbols
        if !is_static_code(llvm_ir)
            if gc_policy == :warn           
                ; # @warn "Non-static LLVM IR detected in method $(m):\n$(llvm_ir)"
            elseif gc_policy == :strict
                ; # error("Non-static LLVM IR detected in method $(m):\n$(llvm_ir)")
            elseif gc_policy == :strip
                ;
            elseif gc_policy == :strip_all
                # Attempt to strip GC-related code from IR
                llvm_ir = strip_gc_allocations(llvm_ir)
            else
                error("Invalid policy: `$(policy)`. Must be one of :warn, :strict, :strip, :strip_all.")
            end
        end

        llvm = extract_llvm(m, llvm_ir, false)
        # Extract module-level variable IDs if present
        #modvar_ids = occursin("@\"jl_global#", llvm_ir) ?
        #             extract_modvars(emit_native(m)) : Int[]

        return new(name, mangled, arg_types, m, llvm)
    end
end
Base.isless(a::MethodInfo, b::MethodInfo) = a.name < b.name
Base.:(==)(a::MethodInfo, b::MethodInfo) = a.mangled == b.mangled

"""
    Base.show(io::IO, mi::MethodInfo)

Pretty-print `MethodInfo` to the given IO stream in a readable format.
"""
function Base.show(io::IO, mi::MethodInfo)
    print(io, "Method: ", mi.name, mi.arg_types)
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
        def_ir, decl_ir = make_modvar_def(value)

        # Only compute source file path symbol once
        # file_path_sym === nothing && (file_path_sym = get_mod_filepath(mod))

        # Create and store ModVarInfo record
        info = ModVarInfo(name, mod, mangled_name, def_ir, decl_ir)
        push!(globals, (ptr, info))
    end

    return globals
end

const base_skip_functions = (
    :throw_boundserror,
)

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
    method.module == Base && (method.name in base_skip_functions) && return

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
            mt = obj.def
            !(mt.module == Core) && collect_methods!(name_map, mt, verbose)
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
    module_map = IdDict{Module,ModuleInfo}()

    # n = length(method_map)
    # p = Progress(n; dt=n<100 ? 1000 : 1, desc="assembe methods...", barglyphs=BarGlyphs("[=> ]"), barlen=50)

    # Iterate over all methods and their mangled names
    for (core_method, mangled_name) in method_map
        mod = core_method.module

        # Create a new ModuleInfo if this module is not already registered
        if !haskey(module_map, mod)
            module_map[mod] = ModuleInfo(mod)
        end

        # Create MethodInfo for this method
        method = MethodInfo(core_method, mangled_name, debug, gc_policy)

        # Register the method in the module's method list
        push!(module_map[mod].methods, method)

        if is_memory_alloc(method.llvm.raw_ir)
            replace_memory_alloc(method)
        end

        llvm = method.llvm
        # Process all global variables referenced by this method
        glob_pairs = Pair{String, String}[]
        for (var_id, glob_names) in method.llvm.addrs[:glob]
            # explicitly defined as module variables as jl_global#XXX
            if haskey(modvar_map, var_id)
                modvar = modvar_map[var_id]
                modvar_mod = modvar.mod

                # Ensure the module containing the global var has ModuleInfo
                if !haskey(module_map, modvar_mod)
                    module_map[modvar_mod] = ModuleInfo(modvar_mod)
                end
                push!(module_map[modvar_mod].modvars, modvar)

                llvm.alias[modvar.mangled] = modvar.llvm_decl
                push!(glob_pairs, glob_names=>modvar.mangled)
            else
                # implicity defined constants
                obj = recover_heap_object(var_id)
                println(method, " ", obj)
                if obj === nothing 
                    @warn("Failed to recover global variable with ID = $(var_id) for method: $(method)")
                else
                    modvars = module_map[mod].modvars

                    # Generate a unique symbolic name and mangle it for LLVM IR usage
                    name = Symbol("_global_$(length(modvars))")
                    mangled_name = mangle_NS(name, mod)

                    # Generate the LLVM definition and declaration for this global variable
                    def_ir, decl_ir = make_modvar_def(obj, true)
                    
                    # Create a ModVarInfo and register it
                    modvar = ModVarInfo(name, mod, mangled_name, def_ir, decl_ir)
                    modvar_map[var_id] = modvar
                    push!(modvars, modvar)
                    llvm.alias[mangled_name] = decl_ir
                    
                    push!(glob_pairs, glob_names=>modvar.mangled)
                end
            end
            n_funcs = length(llvm.funcs)
            for i in 1:n_funcs
                llvm.funcs[i] = replace(llvm.funcs[i], glob_pairs...)
            end
        end # var_id
    end # method_map

    return module_map
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
@inline function is_static_code(ir::String)::Bool
    substrs = Regex(raw"(@ijl_|inttoptr\s*\(i64\s*(\d+)\s*to\s*ptr\)|%pgcstack = )")    
    occursin(substrs, ir) && return false
    return true
end

@inline function is_memory_alloc(ir::String)::Bool
    occursin(r"@\"\+Core\.GenericMemory#(\d+)\.jit\"", ir) && return true
    return false
end

function make_llvm(method::MethodInfo)::String
    llvm = method.llvm
    buf = IOBuffer()
    for (k, v) in llvm.alias
        println(buf, "@$k = $v")
    end
    for (header, func) in zip(llvm.headers, llvm.funcs)
        println(buf, header)
        println(buf, func)
        println(buf, "}\n\n")
    end
    for v in values(llvm.decls)
        println(buf, v)
    end
    for s in llvm.attrs
        println(buf, s)
    end
    String(take!(buf))
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

    ir_from_modvars = join("@$(v.mangled) = $(v.llvm_def)" for v in modinfo.modvars)
    n = write_if_changed(modvar_path, ir_from_modvars, check)

    # Write each method's IR into its own file
    for m in modinfo.methods
        method_path = joinpath(output_dir, String(m.mangled) * ".ll")
        write_if_changed(method_path, make_llvm(m), check)
    end
    return n + length(modinfo.methods)
end


