"""
    ModVarInfo

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
    MethodInfo

Stores compiled LLVM IR and metadata for a Julia method, including mangled name,
argument types, and global module variable address (if any).
"""
mutable struct MethodInfo
    name::Symbol              # Friendly name (or fallback to mangled name)
    mangled::Symbol      # Internal name used for LLVM IR lookup
    arg_types::Tuple          # Tuple of argument types (excluding function type)
    method::Core.Method       # The original method object
    llvm_ir::String           # Extracted LLVM IR code as string
    modvar_ids::Vector{Int}   # List of module-level variable address in LLVM IR

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


struct ModuleInfo
    mod::Module                    # Symbolic file path or name
    mangled::String                # Mangled name of module
    modvars::IdSet{ModVarInfo}     # Used modvars
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


function assemble_modinfo(method_map::IdDict{Core.Method,Symbol}, modvar_map::IdDict{Int,ModVarInfo}, check_ir::Bool = true)::IdDict{Module,ModuleInfo}
    modinfo_map = IdDict{Module,ModuleInfo}()
    n = length(method_map)
    #p = Progress(n; dt=n<100 ? 1000 : 1, desc="assembe methods...", barglyphs=BarGlyphs("[=> ]"), barlen=50)
    for (method, mangled_name) in method_map
        mod = method.module

        if !haskey(modinfo_map, mod)
            modinfo_map[mod] = ModuleInfo(mod)
        end
        minfo = modinfo_map[mod]

        method_info = MethodInfo(method, mangled_name)
        if check_ir && !is_static_code(method_info.llvm_ir)
            error("find non-statice LLVM code from $(method):\n  $(method_info.llvm_ir)")
        end
        push!(minfo.methods, method_info)

        new_names = String[]
        llvm_decls = String[]
        for var_id in method_info.modvar_ids
            if haskey(modvar_map, var_id)
                modvar = modvar_map[var_id]
                my_mod = modvar.mod
                if !haskey(modinfo_map, my_mod)
                    modinfo_map[my_mod] = ModuleInfo(my_mod)
                end
                my_minfo = modinfo_map[my_mod]
                push!(llvm_decls, modvar.llvm_decl)
                push!(new_names, modvar.mangled)
                push!(my_minfo.modvars, modvar)
            else
                error("Cannot find global static variable for $(method) with ID $(var_id)")
            end
        end

        method_info.llvm_ir = join(llvm_decls) * replace_globals(method_info.llvm_ir, new_names)
        #next!(p)
    end

    return modinfo_map
end

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


